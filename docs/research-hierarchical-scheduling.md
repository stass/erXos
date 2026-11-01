# Research record: hierarchical scheduling and the kernel-runtime contract

A point-in-time report of the research behind erXos's two-level scheduling.
It covers every reference of the architecture proposal of 29 October 2026
(v0.2), read in full wherever a copy could be obtained, and the related work
its readers judged important; a hands-on check of Fiasco under HVF and TCG;
and a count of Fiasco's compiled size. For each source it records the
edition read, the ideas erXos adopts and rejects and why, and the numbers
with their conditions. It then sets the mechanisms side by side, maps the
sources onto the experiments of
[design-scheduler.md](design-scheduler.md#performance) and
[design-domains.md](design-domains.md#performance), proposes further
experiments, checks the factual claims of the user's critique of two-level
scheduling, and lists corrections to the proposal's references. The
decisions that use it are in [design-scheduler.md](design-scheduler.md),
[design-kernel.md](design-kernel.md), [design-domains.md](design-domains.md),
[design-runtime.md](design-runtime.md) and [design-system.md](design-system.md).
Findings here are never edited in place; a re-check gets a new record.

**Date:** 2026-10-29: sources obtained and read; Fiasco built, booted and
measured. The record was compiled from the readers' extracts on 2026-10-30;
the items marked *(checked)* were re-read that day in the same downloaded
copies, and the size count was re-run on the same build with identical
totals.
**Host:** Apple M4 Max, 16 cores (12 performance, 4 efficiency), 64 GiB;
macOS 27.0.1 (26A434), Darwin 27.0.0.
**Tools:** `pdftotext` (poppler 26.10.0, the host's installed version) for
text renderings; `shasum -a 256`; Ruby 4.0.7 for the size count; for the
Fiasco check, QEMU 11.1.2 (Homebrew, machine `virt-11.1`), `aarch64-elf-gcc`
16.2.0, `aarch64-elf-binutils` 2.47 and GNU make 4.4.1, with the full list
under [Fiasco under HVF](#fiasco-under-hvf).
**Sources:** the entries below, all accessed 2026-10-29. Local copies are
under `~/erxos-scratch/papers/` (`a/`, `b/`, and figure renders in
`b-render/`), `~/erxos-scratch/borrow/rootserver/l4/` (Fiasco and L4Re
clones and saved L4Re web pages, cloned and saved on 2026-10-29) and
`~/erxos-scratch/src/otp_src_29.1.2/`. The SHA-256 of every download is in
`~/erxos-scratch/papers/a-manifest.sha256` (130 entries) or in the readers'
extracts; each entry below gives the first 16 hex digits of its primary
copy. Downloads were treated as untrusted data: nothing in them was run
except the Fiasco and L4Re builds and boots described under
[Fiasco under HVF](#fiasco-under-hvf).
**Method:** [Method](#method).

## Summary

* **Coverage.** The proposal lists 25 links. Nineteen papers and documents
  were read in full, from the linked copy or an equivalent one (open copies
  for the two IEEE links). The Fiasco and scheduling-constraints
  repositories were read at the files their entries name. The Nemesis link
  is an index page; three Nemesis papers were read instead. The L4Re
  architecture pages on scheduling, IPC and memory were "Under
  Construction". The L4Re Scheduler and vCPU API pages were read through
  the headers they are generated from. More than 60 further sources
  (papers, theses, manuals, mailing-list posts and source trees) were
  read; the most important are under [Related work](#related-work).
* **One shape recurs.** Every system that kept a two-level scheduler
  working keeps an interrupted continuation where it stopped and lets the
  runtime learn of events at its own safe points: Psyche's masked software
  interrupts, Nemesis' resume slot, Barrelfish's disabled save area,
  Akaros's disabled notifications, the Fiasco vCPU's disabled state,
  Tessellation's cleared tick flag. erXos takes the limiting case: every
  preemption is transparent and there are no upcalls at all
  ([Kernel-runtime interfaces](#kernel-runtime-interfaces)).
* **Lost wakeups are prevented by construction, not by care.** Level-valued
  state plus a park that can fail appears in Akaros ("yield can fail"),
  Barrelfish (the yield predicate), Arachne (a CAS on a wakeup word), ghOSt
  (sequence-checked commits) and Nemesis (event counts). erXos's
  `erx_park` compares two epochs under a lock.
* **Lock-holder preemption is mitigated everywhere and solved nowhere.**
  Solaris and Linux keep a bounded deferral of preemption; Linux grants
  5 µs by default and at most 50 µs. erXos's default grace is that maximum,
  and no source measures how long ERTS holds its locks
  ([Lock-holder preemption](#lock-holder-preemption)).
* **Work done for others is paid by the donor** in CPU inheritance
  scheduling, Credo, seL4's passive servers and Nemesis; Resource
  Containers add a passable charge handle but no access control. erXos
  combines call donation, charge words held as capabilities, and a payer
  fallback that seL4's authors criticise in L4 timeslice donation
  ([Hierarchy and flattening](#hierarchy-and-flattening)).
* **Negative evidence.** Every two-level thread system that was abandoned
  was a general-purpose thread library for arbitrary C code (POSIX threads,
  or Win32 threads in Windows); the stated reasons are complexity, poor
  multiprocessor scaling and missing real-time support (NetBSD), an M:N
  library "never developed to its full potential" (FreeBSD), a 1:1 library
  that was simpler and sufficient (Solaris), and a kernel scheduler fast
  enough to make the motivation moot (NPTL)
  ([Negative evidence](#negative-evidence)).
* **Fiasco under HVF.** An EL1 build of Fiasco (snapshot 26.09.0 and commit
  `50bbe8a9`) boots unmodified on the M4 under HVF with Apple's vGIC, on 4
  and 8 CPUs. A null system call costs 29.3 ns and a vCPU round trip 140.4
  to 141.2 ns (median, FPU enabled). The default EL2 build hangs under
  HVF, and Fiasco has no MSIs there for lack of GICv2m code
  ([Fiasco under HVF](#fiasco-under-hvf)).
* **Fiasco's size.** The EL1 build compiles 66,837 nonblank lines of
  preprocessed C++, 28% of it the kernel debugger and trace buffer
  ([Fiasco sizes](#fiasco-sizes)).
* **The three dispatch models.** The literature predicts that a kernel
  thread per lightweight process loses on spawn and exit (28 times in the
  one measurement), on memory by the stack each thread needs, and on
  switches by about 3 to 16 times on the hardware measured, none of it the
  M4; that runtime grants pay mainly under oversubscription and lock
  contention; and that without either, plain one-to-one scheduling of
  executors matches grants when domains do not share CPUs
  ([The three models compared](#the-three-models-compared)).
* **The user's critique** holds up: of its 24 factual claims, 18 are
  supported by the sources read, 4 partly, none is contradicted, and 2
  cannot be checked from what was read; its 4 judgements agree with the
  sources
  ([The user's critique, claim by claim](#the-users-critique-claim-by-claim)).

## Method

* **Readers.** On 2026-10-29 three readers worked from one brief and saved
  extracts with pointers, kept in `~/erxos-scratch/design-hier/` as
  `report-helperA.txt`, `report-helperB.txt` and `report-a2c6357a.txt`:
  * helper A read the L4, Fiasco and seL4 papers and the scheduling
    constraints code itself, added the Fiasco vCPU paper, and merged three
    forks: Composite, Fluke and Mach; ghOSt, Syrup, `sched_ext`, Concord and
    Shinjuku; JX, SPIN, Singularity and Inferno;
  * helper B read Psyche, scheduler activations and Barrelfish (with
    Barrelfish's source) itself, and merged forks for Lithe, Akaros and
    Tessellation, for the negative evidence, and for Arachne, Shenango and
    Caladan;
  * a third reader extracted Converse, CPU inheritance scheduling, Nemesis,
    hierarchical SFQ and Resource Containers, with file hashes.

  Helper A spot-checked about 40 of its forks' numbers and helper B about
  30 quotes and numbers against the text files; all matched. Where two
  extracts overlap, this record follows the one with the more precise
  pointer and notes disagreements.
* **Reading.** "Read in full" means every page of the named copy.
  Pointers `file:line` refer to the text renderings beside each PDF in the
  entry's directory (`.txt`; `.raw.txt` in reading order; `.layout.txt` for
  tables; `sched_act.squeezed.txt` with normalised whitespace); "p." is a
  printed page, "PDF p." a page index, and Fig. and Table the source's own
  numbering. Converse's text layer is unusable and was read from page
  images; the text layers of Hand, Banga et al. and Ford and Susarla drop
  the µ sign, and their units were confirmed on page images.
* **Kinds of number.** A *measured* number names who measured it, how and
  where; a *cited* number gives its source, pointer and platform; an
  *estimate* names its method. *(reading)* marks a value read off a graph,
  *(inferred)* a conclusion drawn from the cited evidence, and
  **unverified** a claim no source read for this record confirms. Numbers
  from different platforms are given with their platform and never
  compared without saying so; HVF and TCG numbers are never compared.
* **Checks for this record**, made on 2026-10-30 in the downloaded copies
  and marked *(checked)* where used:
  * the SHA-256 of 35 primary copies, all equal to the values in the
    manifest or the extracts except one garbled value in an extract
    (below);
  * Rasiukevicius's statement and date, the NetBSD 5.0 announcement and
    change list, Williams on critical-section recovery, preallocated LWPs
    and signals, the FreeBSD 7.0 announcement, the `UPDATING` entry and
    commit messages of the KSE removal, `kse(2)`, Wemm's mail, the Solaris
    white paper on preemption control, Linux's `rseq.rst`, the Windows UMS
    page, Zijlstra's UMCG mail, Turner's slides and the NPTL paper;
  * Stoess's overhead figures, the vCPU paper's passages on preemption and
    on one budget for two threads, Table 5 of the flattening paper, three
    critiques in the seL4 paper, Concord's IPI and polling costs, the 2.4 ms
    upcall path of scheduler activations, Arachne's 10 ms revocation, Fluke's
    Tables 6 and 7, and Hohmuth and Härtig on Fiasco's thread descriptors;
  * the title pages of the two Akaros theses, OTP 29.1.2's `erl_cmd.md` on
    scheduler counts and binding, the saved L4Re pages, and the `l4sys`
    scheduler and vCPU headers at `l4re-core` `e2e2d5af`;
  * Converse's printed page 25 (on a page image), Rhoden's two rules for
    memory the kernel shares with user space, the seL4 paper's statement
    that its kernel is non-preemptible, and the Solaris white paper's
    remark on user-level context switching;
  * the size count of [Fiasco sizes](#fiasco-sizes), re-run.
* **Corrections to the extracts.**
  * The third extract printed a garbled SHA-256 for the Nemesis paper's
    `paper.html`. The manifest and a recomputation agree on
    `ae24148f4dedc1ad39aeba657652d76d23077bc660f039836d6fa5e634d5e664`.
  * Helper A's summary of Fluke's latency table omits the interrupt model
    with one preemption point: 18.7 µs average and 1,272 µs maximum
    (`fluke-osdi99/lepreau.layout.txt:730-734`) *(checked)*.
  * Helper B's "wrong thesis in the prompt" concerns the readers' brief, not
    the proposal, whose Akaros link and label are right
    ([Corrections](#corrections-to-the-proposals-references)).

## The proposal's references

One entry per link of the proposal's reference list, in its order. "Adopted"
and "Rejected" name the erXos mechanism concerned; the mechanisms themselves
are specified in the design documents.

### First-class lightweight processes and mixed runtimes

#### Psyche: first-class user-level threads (1991)

* **Edition.** B. D. Marsh, M. L. Scott, T. J. LeBlanc and E. P. Markatos,
  "First-Class User-Level Threads", SOSP 1991: the Rochester PDF at
  <https://www.cs.rochester.edu/u/scott/papers/1991_SOSP_Psyche_first_class_threads.pdf>,
  accessed 2026-10-29, read in full (`a/psyche-sosp91/`,
  `666bb4064c2dbec0`). Companions: "Design Rationale for Psyche" (ICPP
  1988, pp. 255-262, a scan whose body was read in full,
  `1ed82e019f8d1439`); "Implementation Issues for the Psyche
  Multiprocessor Operating System" (Computing Systems 3(1), 1990, sections
  2.2-2.4, 3.2, 4.3 and 6, `503298cde3c4a743`); "Multi-Model Parallel
  Programming in Psyche" (PPoPP 1990, sections 2 and 4,
  `71ca536f0299ed67`).
* **Mechanism.** The kernel implements virtual processors (VPs); processes
  exist only in user space. A VP writes the name of its current process
  into shared memory, and a process switch changes the name: "new
  processes can be created simply by inventing new names"
  (`psyche-ppopp90` raw text 542-552). The kernel tracks only the call
  chains of processes that moved between protection domains
  (`psyche-compsys90` raw text 302-316). Kernel events reach a VP as
  software interrupts on a user stack when unmasked; when masked they
  queue, sorted by importance, behind a "queued" flag that a "block until
  interrupt" call drains (`psyche-sosp91.raw.txt:296-381`). A user-set
  "two-minute warning" precedes preemption as a flag or an interrupt
  (432-490). A read-only "magic page" publishes run-queue lengths and VP
  times (`psyche-compsys90` raw text 946-963).
* **Adopted.** The logical process as a name that the kernel never sees
  unless it crosses a domain: erXos's pids carry their owner domain and no
  kernel object exists per process
  ([Identity and lifecycle](#identity-and-lifecycle)). Events that wait
  while the runtime is busy and are taken by an explicit call: the events
  word and `erx_park`. A kernel-written read-only page: the status area.
  Delivery to any idle VP of an address space: `erx_group_signal` wakes any
  parked executor.
* **Rejected.** Software interrupts into the runtime (the user's rule 2);
  interrupt vectors per address space, which the authors call "a mistake"
  (`psyche-sosp91.raw.txt:451-460`); probabilistic keys instead of
  capabilities (ICPP 1988); round robin without budgets. The timed warning
  is replaced by deferred preemption, which needs no prediction of when a
  quantum ends ([Lock-holder preemption](#lock-holder-preemption)).
* **Numbers** (cited; BBN Butterfly Plus, MC68020 at 16 MHz):
  * context switch at user level against kernel level: Psyche 51 against
    550 µs; Topaz with FastThreads 37 against 441 µs; PCR 77 µs at user
    level (`psyche-sosp91.raw.txt:800-805`);
  * 16 CPUs and 128 threads: Gaussian elimination of a 512 x 512 matrix
    took 33.8 s on kernel VPs and 22.0 s on user threads (35% less); a sort
    of 4,608 elements 44.3 and 27.1 s (39% less) (p. 9);
  * warning experiment (16 workers, 200 phases of 210 tasks of about
    2.5 ms, 100 ms quantum, 3 ms warning): completion 8.50 and 8.58 s at
    multiprogramming level 1, 40.1 and 16.0 s at level 2, 61.6 and 23.8 s
    at level 3, warning off and on, each within 0.2 s (p. 10); with a
    single central task generator the warning did not help
    (`psyche-sosp91.raw.txt:973-1044`).

#### Scheduler activations (1991, 1992)

* **Edition.** T. E. Anderson, B. N. Bershad, E. D. Lazowska and H. M.
  Levy, "Scheduler Activations: Effective Kernel Support for the
  User-Level Management of Parallelism", ACM TOCS 10(1):53-79, February
  1992, the journal version of the SOSP 1991 paper; the PDF linked from
  <https://homes.cs.washington.edu/~tom/pubs/sched_act.html>, accessed
  2026-10-29, read in full (`a/sched-act/`, `888e419ff2203a6d`). Its text
  layer is OCR, so Tables II, III and V were checked on page images.
* **Mechanism.** The kernel allocates processors to an address space and
  the address space schedules its threads. Four upcalls (add this
  processor, processor preempted, activation blocked, activation
  unblocked) each run on a fresh activation, and a stopped thread "is
  never directly resumed by the kernel" (`sched_act.squeezed.txt:427-440`).
  The address space reports two hints: "add more processors (n)" and "this
  processor is idle" (583-632). Critical sections are recovered rather
  than prevented: the upcall continues a preempted thread in a copy of its
  critical section until it leaves it (633-679, 752-784).
* **Adopted.** The runtime is told how many CPUs it can expect: erXos's
  capacity word, which ERTS follows with `schedulers_online`
  (`erl_process.c:8228` in OTP 29.1.2), changed on the scale of seconds
  rather than at each preemption. Hints only on transitions, never per
  switch: an executor republishes its urgency only when it changes.
* **Rejected.** Upcalls carrying machine state on preemption: ERTS switches
  processes only at reduction safe points, so the registers of an
  interrupted emulator are of no use to its scheduler. Notification by
  preempting a second processor of the same address space. Blocking
  upcalls: erXos executors never block outside their domain. Rhoden's
  critique of the recovery scheme stands: detection by PC range and by
  flag gives false positives and negatives, and two stopped contexts
  holding locks A then C and B then C can deadlock
  (`akaros-klues/EECS-2014-223.txt:1464-1516`).
* **Numbers** (cited; CVAX Firefly, where a procedure call costs about 7 µs
  and a trap about 19 µs):
  * Table IV, in µs: Null Fork 34 (FastThreads on Topaz threads), 37
    (FastThreads on activations), 948 (Topaz threads), 11,300 (Ultrix
    processes); Signal-Wait 37, 42, 441 and 1,840; without the zero-overhead
    critical-section marking, 49 and 48;
  * a signal-wait through the kernel took 2.4 ms, "a factor of five worse
    than Topaz threads", which the authors blame on a Modula-2+ prototype
    (`sched_act.squeezed.txt:882-883`) *(checked)*;
  * Table V, N-body, two jobs on 6 CPUs: speedup 1.29 (Topaz threads), 1.26
    (original FastThreads), 2.45 (FastThreads on activations), of a possible
    3;
  * a few hundred lines added to FastThreads and about 1,200 to Topaz.

#### Converse (1996)

* **Edition.** L. V. Kalé, M. Bhandarkar, N. Jagathesan and S. Krishnan,
  "Converse: An Interoperable Framework for Parallel Programming":
  `newPapers/96-02/paper.pdf` from the page the proposal links,
  <https://charm.cs.illinois.edu/papers/96-02>, 27 pages with an API
  appendix, accessed 2026-10-29, read in full from page images because the
  text layer is unusable (`a/converse/`, `88af5b52a04406e9`). The page
  lists IPPS 1996 and five authors, J. Yelon among them; this PDF's title
  page lists four, Yelon appears only in the acknowledgements, and its
  references to 1995 venues still read "to appear" (pp. 1, 16, 18), so it
  is probably a preprint rather than the proceedings version, which was
  not obtained.
* **Mechanism.** One scheduler per processor runs "generalized messages", a
  handler index plus a payload that stands for a remote message, a ready
  thread or a deferred call; queueing strategies are pluggable; threads
  separate suspend and resume from policy through strategy hooks;
  non-preemptive modules enter the scheduler explicitly with
  `ScheduleFor(n)` or `ScheduleUntilIdle()` (pp. 5-7, 10, 24-25).
* **Adopted.** One executor core over continuations with policy hooks per
  runtime, which makes a second runtime on the same contract cheap: the
  design's `erx_fiber`. Explicit scheduler-entry points are the cooperative
  safe points the runtime contract relies on.
* **Rejected.** Running without preemption: "Preemptive messages (interrupt
  messages) will be investigated in the future" (p. 15), so one handler
  that never yields stalls its processor. erXos's kernel preempts every
  executor.
* **Numbers** (cited): on Myrinet with the FM library, FM delivers a message
  of up to 128 bytes in 25 µs and Converse in about 31 µs; the scheduler's
  queue adds about 9 to 15 µs for short messages (p. 14); a new
  coordination language took "about a day" and about 100 lines of C
  (p. 13).

#### Lithe (2009)

* **Edition.** H. Pan, B. Hindman and K. Asanović, "Lithe: Enabling
  Efficient Composition of Parallel Libraries", HotPar 2009, the page at
  <https://www.usenix.org/legacy/event/hotpar09/tech/full_papers/pan/pan_html/index.html>
  and its PDF (`a/lithe-hotpar09/pan.pdf`, `e02936a646da1571`);
  "Composing Parallel Software Efficiently with Lithe", PLDI 2010,
  pp. 376-387 (`a/lithe-pldi10/`, `45d4e03e8f5950af`, from Asanović's page
  because the project site failed TLS); and chapter 3 of Klues's thesis,
  Lithe on parlib (see [Related work](#related-work)). All accessed
  2026-10-29 and read in full.
* **Mechanism.** Harts are unvirtualised hardware threads that callers
  grant to callees through `request`, `enter`, `yield`, `register` and
  `unregister`; sharing is cooperative, and "preemption is only necessary
  for servicing events like I/O or timers, a task better supported at the
  operating system level" (`pan.raw.txt:138-165`). `unblock` only records a
  context and never resumes it; `ctx_pause(fn)` leaves the stack before
  publishing the continuation (`lithe-pldi2010.raw.txt:389-426`). On
  parlib, hart requests derive from block and unblock deltas, and there is
  "no way for one runtime to forcibly remove a hart from another"
  (`EECS-2015-188.txt:4217-4229, 4835-4837`).
* **Adopted.** Work done for a caller runs on the caller's resources: call
  donation. "Unblock records, never resumes": `erx_executor_wake` advances
  an epoch and wakes a parked executor, nothing more. Lithe's ordering rule,
  leave the stack and only then publish the continuation, has its
  counterpart in the park protocol: read the epochs, then look for work,
  then park with the epochs read.
* **Rejected.** Cooperative sharing across trust boundaries, and a
  scheduler hierarchy that follows the call graph; erXos's group tree
  follows policy and authority, and the kernel preempts.
* **Numbers** (cited; 16-core Opteron at 2.3 GHz, Linux 2.6.18):
  * porting cost: TBB 180 lines added, 5 removed, 70 changed; OpenMP 220,
    35 and 150;
  * SPQR run time in seconds, out of the box, best manual tuning, Lithe:
    landmark 3.2, 2.9, 2.7; deltaX 15.4, 12.0, 10.4; ESOC 73.4, 61.1, 60.4;
    Rucci1 271.7, 265.6, 248.3 (`lithe-pldi2010.txt:602-612`); context
    switches fell up to 47 times (deltaX: 1.04 x 10^6 to 2.21 x 10^4);
  * Klues: Lithe beats the best static tuning by only 2.3 to 10%, and
    "user-level threading alone is the dominant component"
    (`EECS-2015-188.txt:4625-4627, 4810-4814`).

### Hierarchy, dispatch and accounting

#### CPU inheritance scheduling (1996)

* **Edition.** B. Ford and S. Susarla, "CPU Inheritance Scheduling", OSDI
  1996, Seattle: the 15-page render at bford.info of the same `sched.dvi`
  as the USENIX PostScript behind
  <https://www.usenix.org/conference/osdi-96/cpu-inheritance-scheduling>
  (16 pages with a cover; spot checks of Table 1 and the text agree in
  both), accessed 2026-10-29, read in full (`a/cpu-inherit-bford/`,
  `ee27be9d7c500663`). Proceedings page numbers were not verified.
* **Mechanism.** "Threads are scheduled by other threads": a scheduler
  thread donates its CPU to a client, and clients may be schedulers. The
  kernel's dispatcher "inherently contains no notion of thread priorities,
  CPU usage, or even clocks and timers" and only blocks, unblocks and
  donates; a thread that becomes ready triggers a notification to its
  scheduler's port; `schedule(target, port, sensitivity)` donates and
  sleeps in one step (`inherit-sched.raw.txt:286-473`). The donor is
  charged: charging the recipient "would allow the accounting system to be
  subverted" (666-714).
* **Adopted.** Donor pays: an endpoint call is charged to the caller's
  payer, which the server cannot change (invariant S6 of
  design-scheduler.md).
* **Rejected.** A dispatcher with no notion of priority or time: erXos's
  kernel enforces urgencies and quotas itself, because the schedulers above
  it are untrusted. A kernel thread per schedulable entity, which would mean
  one per lightweight process; unbounded depth (the authors suggest a cap of
  four or eight levels, 1072-1079; erXos caps the group tree at eight); a
  root scheduler in user mode, for its cost. Sensitivity hints have nothing
  to suppress in erXos, which makes no kernel-to-runtime invocations.
* **Numbers** (cited; user-level prototype with `SIGVTALRM` preemption on a
  100 MHz Pentium under FreeBSD 2.1.5):
  * dispatch time by hierarchy depth (Table 1, p. 12): 8.0 µs at the root,
    11.2 at 2 levels, 14.0 at 3, 16.2 at 4, 24.4 at 8;
  * scheduler invocations were 41 to 56% of all context switches (Table 2);
  * tolerance: about 300 µs per switch on FreeBSD for a 2% slowdown of gcc,
    about 6 µs on an L4-like kernel (`inherit-sched.raw.txt:1261-1280`);
  * the dispatcher is 550 lines (158 semicolons).

#### Composite (2008)

* **Edition.** G. Parmer and R. West, "Predictable Interrupt Management and
  Scheduling in the Composite Component-based System", RTSS 2008: the
  author copy at
  <https://faculty.cs.gwu.edu/gparmer/publications/parmer_west_rtss08.pdf>,
  12 pages, accessed 2026-10-29, read in full (`b/parmer-rtss08/`,
  `5bdce2cf38fc5617`).
* **Mechanism.** The kernel has no scheduler and no blocking: permitted
  scheduler components switch threads with `cos_switch_thread`, in a
  hierarchy managed by `cos_sched_cntl` with transitive revocation and a
  depth fixed at compile time; only the root creates threads. Interrupts
  become "brands" run by upcall threads with pending counts. A region
  shared between kernel and schedulers holds per-thread urgency, from which
  the kernel decides interrupt preemption at the closest common scheduler.
  The time-stamp counter is read at every switch into per-scheduler
  counters. Critical sections use restartable atomic sequences (at most
  four per component) and locks that help the holder.
* **Adopted.** Interrupts and asynchronous events run on threads of their
  own, so a runtime is never entered to handle them: interrupt objects
  signal notifications or groups, and drivers do the work in workers.
  Kernel accounting of every switch, which the authors say "made
  programming user-schedulers significantly easier": the kernel charges
  every nanosecond to a payer. Thread creation only by the root: only the
  guardian creates spaces.
* **Rejected.** A kernel that reads a live shared region on its scheduling
  paths: the same group later wrote that "the asynchronous access of
  user-level schedulers and the kernel to these regions led to complex,
  inefficient, and buggy code" (temporal capabilities paper,
  `rtss17tcaps.txt:238-241`) *(checked)*. erXos's
  kernel reads three runtime-written words, each with one load through one
  accessor, and validates them. Restartable sequences, which give no
  atomicity across CPUs.
* **Numbers** (cited; Pentium 4 at 2.4 GHz, cycles): component RPC 1,629;
  thread switch 529, 688 through a scheduler, 976 with accounting; upcall
  executed at once 3,442; upcall dispatch latency 1,768; Linux null system
  call 502, `sched_yield` 1,903, uncontended futex 411; `rdtsc` 80.

#### Stoess, user-controlled L4 scheduling (2007)

* **Edition.** J. Stoess, "Towards Effective User-Controlled Scheduling for
  Microkernel-Based Systems", ACM SIGOPS Operating Systems Review 41(4),
  July 2007, pp. 59-68 (the page range from the RTAS 2026 paper's
  references): the KIT author PDF at
  <https://os.itec.kit.edu/downloads/publ_2007_stoess_user-controlled-l4sched.pdf>,
  10 pages, accessed 2026-10-29, read in full (`b/stoess07/`,
  `06aece095b74b0a9`).
* **Mechanism.** L4Ka::Pistachio with all scheduling state removed: no
  slices, priorities or ready queues, and the timer is an ordinary
  interrupt. Exactly one thread per CPU is runnable; blocking on a single
  destination transfers both control and time. On a forced preemption the
  kernel synthesises a preemption IPC from the preempted thread to its
  scheduler thread, carrying its registers; the reply re-grants the CPU and
  may install changed registers. Preemptions chain up the hierarchy to the
  lowest common scheduler.
* **Adopted.** The preempted continuation stays frozen in the kernel while
  another party decides; the runtime is never re-entered on the preempted
  stack.
* **Rejected.** Vectoring every preemption to user level, for its cost; and
  scheduling without kernel-enforced budgets: "nothing prevents a high
  priority thread to activate a low priority thread", and the paper admits
  no control over "priority inversion and time isolation".
* **Numbers** (cited; Pentium D 830 at 3 GHz, one core, 2 ms tick):
  * "hierarchical preemption incurs between 1.4µs and 2.1µs overhead" per
    level, "about 156 µs per timer tick of 2 ms maximum overhead under high
    I/O load, or 7.8 percent", and application overhead "between 0 and 10
    percent compared to a pure in-kernel scheduler"
    (`stoess07.txt:36, 139, 598-603`) *(checked)*;
  * Fig. 7, preemptions per tick and interrupt latency: idle 0 and
    1.15 µs; CPU load 3 and 2.78 µs; network 16 and 2.22 µs; network and CPU
    48 and 3.26 µs;
  * Fig. 8, netperf MB/s and ab requests per ms with the user-level
    scheduler, the original L4 scheduler and native Linux: netperf with CPU
    load 933, 930, 940; ab 27.8, 31.3, 146.2; both together 934 and 13.4,
    151 and 29.6, 940 and 97.0. The original scheduler cut netperf by 84%
    by counteracting the guest;
  * call round trips (Fig. 6, readings): within an address space about 540
    to 830 cycles, between address spaces about 1,500 to 2,100.

#### Barrelfish: architecture and dispatchers (2013)

* **Edition.** "Barrelfish Architecture Overview", Barrelfish Technical
  Note 000, 4 December 2013:
  <https://barrelfish.org/publications/TN-000-Overview.pdf>, accessed
  2026-10-29, sections 1.1 to 1.3 read in full (`a/barrelfish-tn000/`,
  `47f5ec13999f1eb5`). TN-000 is an overview; the dispatcher details below
  come from its companions: TN-009 "Message Notifications" (16 June 2010,
  read in full), TN-021 "CPU drivers in Barrelfish" (1 December 2015,
  skimmed), Baumann et al., "The Multikernel", SOSP 2009 (author version,
  sections 4.3 to 4.8), Peter et al., "Design Principles for End-to-End
  Multicore Schedulers", HotPar 2010 (read in full), S. Peter, "Resource
  Management in a Multicore Operating System", Diss. ETH No. 20664, 2012
  (sections 2.5.2, 2.5.5, 3.2.5, 3.3.2, 3.5, 3.6, 4.1.1, 4.2), and the
  kernel and library source at commit `06a9f547`, read line by line by
  helper B.
* **Mechanism.** One single-threaded, non-preemptible CPU driver per core
  schedules dispatchers, "a form of scheduler activations"
  (`TN-000.raw:129-136`). A dispatcher is disabled when its `disabled` word
  is set or its PC lies in `[crit_pc_low, crit_pc_high)`; a preempted
  disabled dispatcher is saved to its disabled area and resumed exactly
  there, an enabled one to its enabled area and later entered through its
  Run upcall (`kernel/dispatch.c:60-129`). Yield may only be called while
  disabled, and removes the dispatcher from the run queue only if it has no
  work, no undelivered message and no missed wakeup
  (`kernel/syscall.c:699-780`). Faults while disabled go to a third area;
  after two the domain becomes unrunnable (`exn.c:46-62`). TN-009 publishes
  the running dispatcher and its next preemption, so a sender can skip the
  interrupt when the receiver is already running.
* **Adopted.** Resume in place for a preempted runtime, here for every
  preemption. A predicate over counters that makes a missed wakeup
  impossible: the two epochs of `erx_park`. No interrupt for a receiver
  that is running: `erx_group_signal` with no parked executor only sets
  bits, which a running executor takes at its next safe point.
* **Rejected.** The Run upcall and the PC-range test, which the source itself
  calls "totally flakey" (`lib_barrelfish_arch_aarch64_dispatch.c:137-138`)
  *(checked)*. Helper B's reading of the kernel (not tested) found what a
  user-writable save area costs: a saved `SPSR` whose mode is only asserted,
  then masked so that EL1h survives when assertions are off (`exec.c:36-47`);
  a double fetch of `SPSR` (`exceptions.S:493-495`); assertions on re-read
  shared state (`exn.c:267-277`, `syscall.c:1276-1281`); and a self-flagged
  leak of kernel stack to the fault handler (`exn.c:76-77`). erXos keeps saved
  registers in kernel memory and loads each runtime-written word once.
* **Numbers** (cited):
  * Multikernel Table 1, one-way user-to-user LRPC including the upcall,
    message dispatch and a scheduler pass: 845 cycles or 318 ns (2 x 4
    Intel, 2.66 GHz); 757 or 270 ns (2 x 2 AMD, 2.8 GHz); 1,463 or 585 ns
    (4 x 4 AMD, 2.5 GHz); 1,549 or 774 ns (8 x 4 AMD, 2 GHz); raw L4 IPC
    about 420 cycles on the 2 x 2 AMD;
  * TN-009: a notification costs 350 cycles with a shared L3 and 450
    across packages; the send path 2,800 and an activation about 2,000;
    polling with three domains took up to 10,000 cycles to notice a
    message, and without notifications at least one tick;
  * Peter's thesis: a Linux futex block about 7.37 µs against 40 ns per
    spin iteration; a context switch 4 µs on the 4 x 4 AMD; phase-locked
    and interrupt-driven gang scheduling equal down to 500 µs slices, the
    former 36% better at 20 µs slices where switching costs 20% of each
    slice.

#### Flattening hierarchical scheduling (2012)

* **Edition.** A. Lackorzyński, A. Warg, M. Völp and H. Härtig, "Flattening
  Hierarchical Scheduling", EMSOFT 2012, Tampere, pp. 93-102: the TU
  Dresden author copy at
  <https://os.inf.tu-dresden.de/papers_ps/emsoft12-lackorzynski.pdf>, 10
  pages, accessed 2026-10-29, read in full (`b/lackorzynski-emsoft12/`,
  `9cc2133f8643e3e5`).
* **Mechanism.** Two mixed-criticality task sets are infeasible with one
  budget per virtual machine for any budget, and feasible with several
  interleaved budgets per machine at different global priorities. The host
  admits several scheduling contexts (priority, budget, period) per vCPU;
  `set_sc(id)` switches the active one, and `register_event(id, event, fn)`
  binds an interrupt to a context. A default context at the lowest
  priority runs best-effort work. Implemented in Fiasco.OC with vCPUs.
* **Adopted.** Bands: a runtime's priorities map onto a few child groups,
  each with its own ceiling and quota, which an executor names in its
  charge word while it runs a process of that band (design-scheduler.md,
  Charge words). The mapping is enforced, since a runtime that runs
  everything in its top band spends only that band's quota, and needs no
  kernel object per process.
* **Rejected.** Nothing of the idea; the paper's own limit is that only
  static priorities map, so EDF guests do not. ERTS's four priorities do.
* **Numbers** (cited; AMD Phenom 8450 at 2.1 GHz): switching the active
  context costs 795 cycles (0.4 µs) paravirtualised and 5,863 cycles
  (2.8 µs) fully virtualised (Table 5) *(checked)*; no measurable overhead
  when contexts do not switch; guest changes of 10 lines for FreeRTOS and
  22 for Linux (Table 4). Linux's `irq_no_sched()` masks interrupts "to
  atomically check the rescheduling condition with the actual operation",
  so a band switch belongs at a safe point.

#### Nemesis resource accounting

* **Edition.** The proposal links the Cambridge NetOS papers index,
  <https://www.cl.cam.ac.uk/research/srg/netos/papers/>, not a paper. Three
  sources were read instead, accessed 2026-10-29:
  * I. M. Leslie, D. McAuley, R. Black, T. Roscoe, P. Barham, D. Evers,
    R. Fairbairns and E. Hyden, "The Design and Implementation of an
    Operating System to Support Distributed Multimedia Applications", IEEE
    JSAC 14(7):1280-1297, September 1996, which "describes state in May
    1995" (`a/nemesis-hand-osdi99/hand.raw.txt:1516-1521`); only the
    authors' latex2html render of 25 June 1997 was available, from a 2014
    Wayback capture of the old Pegasus page; all 38 sections read
    (`a/nemesis-jsac96/`, `paper.html` `ae24148f4dedc1ad`); latex2html
    dropped some formulas and tables, which the thesis supplies;
  * T. Roscoe, "The Structure of a Multi-Service Operating System",
    Cambridge TR-376 (DOI 10.48456/tr-376), August 1995, 113 pages:
    chapters 1, 2, 4 and 6 and sections 5.4 to 5.6 read
    (`a/roscoe-thesis/TR376.txt`, `e779df38c189a6b3`);
  * S. M. Hand, "Self-Paging in the Nemesis Operating System", OSDI 1999,
    read in full (`a/nemesis-hand-osdi99/`, `9b2eee4f22a1e7bb`).
* **Mechanism.** The kernel is interrupt and trap handlers only. A domain
  is "normally upcalled rather than being resumed"; "the exceptional case
  of a resumption is only used when the domain is operating within a
  critical section", chosen by an activation bit in its control block:
  preemption saves into the resume slot while the bit is clear and into
  the activation slot while it is set, and rescheduling then clears the
  bit and upcalls (`jsac96-combined.txt:650-677`). Events are monotonic
  counts that "never lose events", with a FIFO of endpoint indices, sent by
  87 PALcode instructions that read only fields the domain cannot write;
  a send is a hint that does not force a reschedule
  (`TR376.utf8.txt:2345-2413`). Atropos gives each scheduling domain
  `{s, p, x, l}` (slice per period, slack flag, unblocking latency) under
  EDF on implicit deadlines, with admission below 100% by a QoS manager.
  Interrupts are masked on delivery and unmasked when the driver runs.
  Hand moves paging out of the kernel and revokes memory by asking a domain
  to "release k frames by time T", else killing it (`hand.raw:481-503`).
* **Adopted.** The accounting principle: "service requests should as far as
  possible be performed using CPU time accounted to the client and by a
  thread under control of the client" (`TR376.utf8.txt:782-783`), which
  erXos meets with call donation and charge words. Sends as hints: a group
  signal wakes at most one parked executor and never forces a running one.
  Interrupts masked until the driver has run: a fired interrupt object
  stays masked until `erx_irq_ack`.
* **Rejected.** The activation bit and its two slots, because rule 2 allows
  no upcall at all. Atropos and its deadlines (design-scheduler.md,
  Alternatives). "Services in the client" as the main defence against
  crosstalk: erXos's services are Erlang domains of their own, which is
  why it needs charge words. Nemesis itself rejected Psyche-style warnings
  as "unnecessary" because applications "adapt their behaviour over longer
  time scales" (`TR376.utf8.txt:2538-2543`), thread tunnelling because
  "applications can no longer reliably internally multiplex the CPU"
  (`jsac96-combined.txt:1657-1664`), and processor capacity reserves
  because there is "no guarantee that a server will deal with clients
  fairly, or that clients will correctly 'pay'" (`jsac96-combined.txt:528-541`).
* **Numbers** (cited; DEC 3000/400 Alpha 21064, scheduler driven by a 122 µs
  ticker):
  * fastest reschedule 1.37 µs, most under 4 µs, under 2% overhead at one
    reschedule per 122 µs (7 domains, about 77% committed;
    `TR376.utf8.txt:2839-2879`);
  * event delivery about 2.3 µs; null RPC about 30 µs against Mach 88 µs and
    Opal 122 µs on the same hardware, of which scheduling 29%, events 20%,
    activation handler 47%, stubs 4%;
  * over 60% of an application's CPU time unaccounted to it on SunOS
    rendering video through X (`TR376.utf8.txt:765-775`, citing Pratt 1994);
  * Hand, on a PC164: the page-fault "trap" benchmark took 4.20 µs against
    10.33 µs on OSF/1 4.0; paging progress "very close to 4 : 2 : 1" for
    shares of 4 : 2 : 1 on an EB164.

#### Akaros: many-core processes and core grants (2014)

* **Edition.** B. Rhoden, "Operating System Support for Parallel
  Processes", UCB/EECS-2014-223, 18 December 2014, 182 pages:
  <https://www2.eecs.berkeley.edu/Pubs/TechRpts/2014/EECS-2014-223.html>,
  accessed 2026-10-29; chapters 1 and 3 to 7 read in full, 2 and 8 skimmed
  (`a/akaros-klues/EECS-2014-223.pdf`, `dbe7a10a809cdc2d`; the directory
  name is a misnomer). Read with it: K. Klues, "OS and Runtime Support for
  Efficiently Managing Cores in Parallel Applications", UCB/EECS-2015-188,
  13 August 2015 (see [Related work](#related-work)). The title pages were
  checked *(checked)*.
* **Mechanism.** A many-core process (MCP) is granted vcores, not threads:
  "There are no kernel tasks or threads underlying each thread of a
  process", and "All system calls are asynchronous and never block the
  user's core" (`EECS-2014-223.txt:1710-1714`). Provisioning is an
  irrevocable guarantee; allocation follows a shared request the kernel
  reads (1840-1884). Per vcore, a read-only page holds the vcore map and
  preemption counters, and a writable page holds two context slots,
  `notif_disabled`, `notif_pending` and mailboxes; a vcore preempted while
  notifications are disabled "will restart exactly where it left off"
  (2389-2434). Vcore context must not take a hard page fault, or the MCP is
  killed (2440-2446). Kernel messages are per core, ordered and reliable
  (2541-2626). "Yield can fail" (5132-5229). Locks that advertise their
  holder let spinners make sure the holder runs (PDR locks, 5658-6889).
* **Adopted.** The executor's view of the kernel as two pages, one it
  writes and one only the kernel writes. A park that can fail. An ordered
  control channel applied at one point per CPU (cross-CPU requests).
  Provisioning against allocation, in the form of cpusets and capacity.
* **Rejected.** Upcalls into vcore context. The event-delivery option
  matrix, of which Klues writes that "a majority of the features ... exist
  soley to ensure that messages never get lost"
  (`EECS-2015-188.txt:1993-2016`). Kernel-grown queues, which conflict with
  budgets. Remote stealing of user threads, which Rhoden doubts pays
  (`EECS-2014-223.txt:7150-7154`).
* **Disagreement between the sources.** Klues says an MCP is not preempted
  "without first being notified" (`EECS-2015-188.txt:623-625`); Rhoden says
  the scheduler "immediately preempts cores"
  (`EECS-2014-223.txt:5438-5439`). Rhoden's "over 50 billion quanta" for
  an FTQ run (4023-4025) is implausible at a 10 kHz sampling rate and is
  quoted only as printed.
* **Numbers** (cited; Xeon E5-2670 at 2.6 GHz): user-thread switch 172 ns
  for 2 threads and 221 ns for 1,000 without TLS, 340 and 408 ns with TLS,
  against 465 and 812 ns for Linux pthreads; a directed switch 55 ns
  (3157-3244); a spin PDR lock costs about 16 cycles more than a plain one;
  under periodic 10 ms preemption of 2 vcores, plain MCS lock throughput
  falls to 0 and MCS-PDRO to about 250 locks per ms (6375-6385);
  fluidanimate (Table 7.1, 7272-7278) *(checked)* took 66.95 s with 32
  threads on 32 Linux cores and 70.24 s on 31 Akaros cores, but with 512
  threads 221.00 s on Linux against 71.73 s on Akaros: oversubscribed
  kernel threads interfered, user threads did not, and the best cases
  differ by about 2% in Linux's favour; the Go port took 1.5 years and
  still used a pthread emulation layer
  (`EECS-2015-188.txt:4874-4876, 4986-4996`).

### Modern kernel and resource mechanisms

#### L4Re/Fiasco source

* **Edition.** The proposal links <https://github.com/L4Re/fiasco>. What
  was read and built is the clone of <https://github.com/kernkonzept/fiasco>
  at commit `50bbe8a9` (2026-10-14, still the head on 2026-10-29), cloned
  2026-10-29, and the Fiasco tree of the L4Re snapshot 26.09.0 (published
  2026-09-27; archive SHA-256 `6c24687b22e1fca1`, matching the published
  `SHA256SUM`). Whether the proposal's URL serves the same history was not
  checked. The two trees differ in 58 `diff -rq` entries, and a snapshot
  user land does not boot a `50bbe8a9` kernel
  ([Fiasco under HVF](#fiasco-under-hvf)). The files named below were read
  by helper A and by the earlier root-server evaluation
  (`~/erxos-scratch/draft/research-results/root-server-evaluation.md`,
  2026-10-29), whose pointers marked checked there were re-read.
* **Mechanism, scheduling.** Each `Context` embeds one scheduling context
  (`src/kern/context.cpp:394-395, 665-666`) with a fixed priority from 1 to
  255 and a quantum (`sched_context-fixed_prio.cpp`); per-CPU ready queues
  by priority run round robin within a level (`ready_queue_fp.cpp`); the tick
  is `CONFIG_SCHED_GRANULARITY` (1,000 µs) and the default slice 10 ticks
  (`Kconfig:366-381`; the measured build has
  `CONFIG_SCHED_DEF_TIME_SLICE=10`, and its kernel debugger shows
  "timeslice: 10000 us" *(checked)*). A slice that expires only requeues
  its thread (`timeslice_timeout.cpp:34-49`). The IPC direct switch keeps
  the sender's scheduling context when the sender waits for the reply
  (`thread-ipc.cpp:762-779`), but `schedule_switch_to_locked` installs the
  chosen thread's own context (`context.cpp:1148-1163`), so a donation
  lapses at the next scheduling decision. Time is charged to the executing
  `Context` (`context.cpp:1126-1139, 1292`). Helping lives on in
  `switch_exec_helping` (`context.cpp:1243-1260`) and `Switch_lock`;
  `Pi_mutex` is enabled by default (`CONFIG_PRIO_INHERIT`). Other CPUs are
  reached through cross-CPU requests.
* **Adopted.** Per-CPU fixed-priority ready queues with round robin within
  a level (erXos has 64 urgency levels); cross-CPU requests that keep
  per-CPU structures free of locks; IPC timeslice donation, made to last
  until the reply in the stopgap; the `Ram_quota` hierarchy as the
  stopgap's budgets (design-kernel.md, The current implementation).
* **Rejected** for erXos's own kernel: a kernel stack per thread, a
  preemptible kernel and helping locks
  ([Kernel execution models](#kernel-execution-models)); the mapping
  database; read-copy-update reclamation (design-kernel.md, No grace
  periods).
* **Numbers.** Measured on the M4 under HVF by the Fiasco check: null system
  call 29.3 ns, vCPU round trip 140 to 141 ns
  ([Fiasco under HVF](#fiasco-under-hvf)); size
  ([Fiasco sizes](#fiasco-sizes)). Cited from
  <https://l4re.org/performance.html> through the root-server evaluation
  (checked there): one-way IPC within a task, between tasks, and a system
  call cost 247, 384 and 138 cycles on a
  Cortex-A76 at EL1, and 562, 691 and 230 on a Cortex-A53. The repository
  had 936 commits in the year to 2026-10-29 (root-server evaluation).

#### L4Re architecture

* **Edition.** <https://l4re.org/detailed_introduction/index.html>. Its
  index page was not saved; the pages beneath it that concern this record
  were saved on 2026-10-29 (`~/erxos-scratch/borrow/rootserver/l4/web/`),
  each "Last updated on 2026-10-26": the architecture overview, and the
  concept pages "Thread scheduling", "L4 Inter-Process Communication (IPC)"
  and "Memory Management". All three concept pages read "Under
  Construction"; the IPC and memory pages refer to the Doxygen
  documentation *(checked)*.
* **Content.** The overview describes a microkernel that alone runs
  privileged, a runtime environment whose most basic parts are the root
  pager `sigma0` and the root task `moe`, applications, and virtual machines
  run by a user-level monitor. It says nothing about scheduling.
* **Adopted.** The layering informs the stopgap's import: Fiasco's kernel,
  `bootstrap` and `sigma0` only (design-kernel.md).
* **Rejected.** `moe` and `ned` as erXos's root task (design-system.md,
  Alternatives considered).
* **Numbers.** None.

#### L4Re Scheduler API

* **Edition.** <https://l4re.org/doc/group__l4__scheduler__api.html> was
  not fetched. Its Doxygen source, `l4sys/include/scheduler.h` in
  `l4re-core` at `e2e2d5af` (2026-10-21, still the head on 2026-10-29,
  cloned that day), was read *(checked)*, with Fiasco's
  `src/kern/scheduler.cpp` as read by helper A.
* **Mechanism.** A scheduler kernel object with operations info (0),
  run thread (1) and idle time (2), and an online test per CPU.
  `l4_sched_param_t` carries an affinity (a CPU set with granularity and
  offset), a priority from 1 to 255 ("Priority 0 is reserved for the
  kernel") and a quantum in microseconds. The classes are fixed priority and
  weighted fair queuing.
* **Adopted.** Affinity masks per thread (`erx_thread_set_affinity`) and
  per-CPU usage as kernel-reported inspection data (`erx_group_info`).
* **Rejected.** Priority and quantum per thread as the whole model of CPU
  time: it has no budget per group, which is what the scheduling
  constraints add, and whoever holds the scheduler object may set any
  priority up to 255. erXos clamps every urgency to the ceiling of the
  group that pays (invariant S5).
* **Numbers.** None.

#### L4Re vCPU API

* **Edition.** <https://l4re.org/doc/group__l4__vcpu__api.html> was not
  fetched. Its Doxygen source, `l4sys/include/vcpu.h` at `e2e2d5af`, was read
  *(checked)*, with Fiasco's `vcpu.cpp`, `context-vcpu.cpp` and
  `thread-vcpu.cpp` (helpers A and B), the primary paper
  ([Related work](#related-work)) and the measurement on the M4.
* **Mechanism.** A thread in vCPU mode has a state area in kernel-user
  memory: registers, IPC state, and state and saved-state words whose flags
  are `L4_VCPU_F_IRQ` (0x01), `_PAGE_FAULTS` (0x02), `_EXCEPTIONS` (0x04),
  `_USER_MODE` (0x20) and `_FPU_ENABLED` (0x80), plus a sticky
  `L4_VCPU_SF_IRQ_PENDING`. Entering user mode enables interrupts, page
  faults and exceptions; an upcall disables them. `vcpu_resume_commit` runs
  a user task by switching `TTBR0_EL1` to its ASID without a TLB flush; a
  system call in the user task becomes an exception upcall
  (`thread-arm-64.cpp:130-156`, checked in the root-server evaluation).
  Events are upcalled only when their flag is enabled
  (`thread-vcpu.cpp:121`); a slice that expires only requeues the thread,
  so in `50bbe8a9` a preempted vCPU resumes where it stopped.
* **Adopted.** The semantics of a vCPU with its events disabled: preempted
  transparently, with events left pending in a word it reads when it
  chooses. An erXos executor behaves like such a vCPU at all times.
* **Rejected.** Upcalls, by the user's rule 2 and on cost: a vCPU round trip
  costs 140 ns on the M4, about 4.5 times a crossing with an address-space
  switch.
* **Numbers.** Measured on the M4 under HVF by the Fiasco check: round trip
  (resume into a user task, `svc`, upcall back) 140.4 to 141.2 ns median with
  the user task's FPU enabled and 180.5 to 183.7 ns with it disabled; under
  TCG 11.7 and 12.4 µs ([Fiasco under HVF](#fiasco-under-hvf)). The 2010
  x86 figures are under [Related work](#related-work).

#### Scheduling constraints (RTAS 2026)

* **Edition.** M. Lumme, M. Roitzsch and A. Lackorzyński, "Scheduling
  Constraints: A Universal OS Mechanism for Managing Shared Resources",
  IEEE RTAS 2026, Saint-Malo, DOI 10.1109/RTAS68450.2026.00042. The
  proposal's IEEE page (<https://ieeexplore.ieee.org/document/11558383/>)
  returned an empty response; the open camera-ready linked from L4Re's
  research page, `os.inf.tu-dresden.de/papers/rtas2026-l4re-sched-constraints.pdf`
  (PDF eXpress 2026-03-30, 14 pages), was read in full, figure values from
  220-dpi renders (`b/l4re-rtas26/`, `f0b4cdc741ebb257`). Accessed
  2026-10-29.
* **Mechanism.** A scheduling constraint is a kernel object holding one
  boolean. A thread runs only while every constraint attached to it is
  true (conjunction; disjunction showed "significant overheads"). The
  check happens in `schedule()`: a candidate whose constraints fail is
  removed from the ready queue and registered on the failing constraint,
  and setting the constraint true requeues every registered thread. At
  each context switch the outgoing thread's constraints are deactivated and
  the incoming thread's activated, so a budget constraint saves its
  remainder and re-arms its timer. Donation and helping carry the donor's
  whole constraint set. Constraints whose last capability is gone become
  quiescent and "still enforce their condition", and a restarted manager
  can take them over. Priorities stay a thread attribute: "We also
  considered subsuming thread priorities into the SC mechanism, but
  ultimately decided not to."
* **Adopted.** Conjunctive caps along the group path: a thread runs only
  while every group on its payer's path has quota (invariant S5). Lazy
  throttling with a list per group and CPU. Fail-closed enforcement that
  outlives the policy holder. Priority kept apart from budget (urgency and
  quota). Grants changed only by the policy, which alone holds `CONFIGURE`.
* **Rejected.** Booleans set by user-level servers as the budget mechanism
  (the paper keeps its own budget and bandwidth servers in the kernel and
  notes "deadlocks are still possible for resource servers in userspace");
  CPU masks supplied by the caller; disjunction.
* **Numbers** (cited; Raspberry Pi 4, four Cortex-A72 at 1.5 GHz, a
  development kernel used for relative numbers):
  * Fig. 3, IPC round trip in cycles: the text gives about 981 within one
    CPU and address space, 1,255 across address spaces and 7,486 across
    CPUs, "agnostic to SCX size";
  * Fig. 4, context switch in cycles for 0, 1, 2, 4, 8, 16, 32 and 64
    constraints per thread, one address space: 796, 828, 861, 935, 1,070,
    1,332, 1,775, 2,738; one constraint adds 32 cycles in one address space
    and 37 across two (readings);
  * Table II, run time normalised to the baseline: 1.000039 (pi), 1.000800
    (a Linux virtual machine), 1.030476 (producer-consumer), 1.053397
    (OpenMP);
  * Fig. 5, cost of flipping a constraint against affected cores 1 to 4:
    asynchronous 633, 1,409, 1,713, 2,006 cycles; synchronous 633, 2,917,
    3,639, 4,228 (readings);
  * a critical task kept its deadlines while a best-effort task used up to
    60% of the CPU under budgets in a 10 ms period.

#### Scheduling constraints: research implementation

* **Edition.** <https://github.com/l4re/sched-constraints> at commit
  `4e9a1a9b56d63ac6bc31cf07226d3785305903ae` (2026-05-12), whose baseline
  is `l4re-base-23.04.02` (`3ef9d6e6`); the kernel diff against it is 46
  files, +3,466 and -438 lines, and userland about 3,150 lines. Accessed
  2026-10-29; the kernel diff and the scheduler proxy were read by helper A
  (`b/sched-constraints-repo/`).
* **Mechanism.** `Sched_constraint` (`kern/sched_constraint.cpp:16-80`)
  with types for a condition, a time slice, a budget (a deferrable
  server), a time window and memory bandwidth through the PMU; a static
  array of at most `Scx_max_sc` constraints per thread (default 4, range 1
  to 64, `Kconfig:304-310`); the check in `schedule()`
  (`context.cpp:804`); the switch in `Ready_queue::set_current`
  (`ready_queue.cpp:184-236`); remote CPUs reached by interrupt
  (`stop_everyone`, 413-455); a scheduler proxy that attaches a global
  constraint to every thread it starts and clamps priorities
  (`moe/server/src/sched_proxy.cc:142-171`).
* **Findings from reading the code** (helper A; untested):
  * a budget constraint has one timeout, armed on the current CPU, and
    `Timeout::set` asserts it is not already set, so one budget shared by
    threads running at once on two CPUs is unsupported;
  * the CPUs that receive interrupts when a constraint changes come from a
    caller-supplied mask (`scheduler.cpp:252-281`), marked
    flagged "IMPORTANT!!!" by a comment in the example;
  * panics and assertions are reachable from requests (a contended
    synchronous constraint, double attach, detaching an unattached
    constraint, a thread without constraints, a short message), and the
    rights returned by the capability lookup are ignored in attach and
    detach (`scheduler.cpp:168-233`);
  * a bandwidth timeout sets the condition true and then stops every CPU
    (`sched_constraint.cpp:1344-1351`), which looks inverted
    (**unverified**).
* **Adopted.** The shape, not the code: a kernel object attached to many
  threads, checked at dispatch and switched with the running thread.
  erXos's group keeps one pool per period and a local slice per CPU, so a
  group's threads may run on several CPUs at once, and the CPUs it affects
  derive from its threads, never from the caller.
* **Rejected.** Importing the artifact: it is a research prototype that
  panics on requests, which erXos's "never panic" rule forbids.
* **Numbers.** Those of the paper.

#### seL4 scheduling-context capabilities (2018)

* **Edition.** A. Lyons, K. McLeod, H. Almatary and G. Heiser,
  "Scheduling-Context Capabilities: A Principled, Light-Weight
  Operating-System Mechanism for Managing Time", EuroSys 2018, Porto,
  article 26, DOI 10.1145/3190508.3190539: the PDF at
  <https://sel4.systems/Research/pdfs/scheduling-context-capabilities.pdf>,
  16 pages, accessed 2026-10-29, read in full (`b/sel4-sc-eurosys18/`,
  `3e0a233daa293b91`).
* **Mechanism.** A scheduling context is a capability object holding a
  budget, a period, a core and a sporadic-server refill list (at least
  256 bytes, eight refills on 64-bit machines); a thread runs only with
  one. Priority stays a thread attribute, bounded by a maximum controlled
  priority taken from an explicitly passed thread to avoid a confused
  deputy. A non-zero budget is admission and needs the per-core
  `sched_control` capability. A passive server has no context of its own
  and runs on its caller's until it replies; reply objects return the
  context to its owner through nested calls; donation stays on one core. A
  thread whose budget runs out sends a timeout fault to a handler, whose
  options include an emergency budget, a criticality switch, killing, or
  rolling back the server. The kernel is tickless and non-preemptible,
  checks on entry that a thread has enough budget to finish its operation,
  and charges time only when the context changes.
* **Critiques in the paper** *(checked)*: hierarchical delegation suffers
  "algorithmic utilisation loss" (citing the flattening paper), so time
  capabilities "cannot support hierarchical delegation without loss"
  (`scheduling-context-capabilities.txt:148-156`); with L4 timeslice
  donation "the time slice may expire during the server's execution, after
  which the server will run on its own time slice" (335-336); helping and
  bandwidth inheritance "make the waiting client pay for another client's
  contract violation" (352).
* **Adopted.** A server answering a call is charged to its caller and keeps
  that payer until it replies, across every preemption (call donation);
  admission held by the policy; per-core accounting (erXos's per-CPU local
  slices); the immediate priority-ceiling protocol through an endpoint's
  floor; charging only at accounting points.
* **Rejected.** The restrictions that come from verification. A single
  passive server migrating across cores, which did not scale (Fig. 12).
  The paper's answer to a client whose budget runs out mid-call (a timeout
  fault to a handler): erXos continues the call on the server's own grant,
  the behaviour the paper criticises in L4 timeslice donation
  ([Hierarchy and flattening](#hierarchy-and-flattening)).
* **Numbers** (cited; i.MX6 Cortex-A9 at 1 GHz and Haswell i7-4770 at
  3.1 GHz; cycles, base and MCS kernels):
  * ARM: call 288 and 350 (+21%), replyRecv 313 and 339, interrupt latency
    1,604 and 1,813, signal 138 and 144, schedule 1,910 and 2,778 (+45%,
    averages of 10,000 runs, from reading and reprogramming the timer);
  * x64: call 448 and 455, replyRecv 431 and 450, interrupt latency 1,144
    and 1,245, signal 136 and 136, schedule 1,512 and 2,100 (+38%);
  * Redis YCSB-A in kops/s: 138.7 on the base kernel and 138.5 on MCS, both
    with the APIC timer; 144.1 on bare metal;
  * timeout handlers, cold cache: rollback 23.3 µs on ARM and 4.57 µs on
    x86, emergency budget 13.6 and 2.43, extending the budget 7.1 and 1.13,
    kill 22.1 and 4.36;
  * about 2,000 lines added (14%).

#### ghOSt (2021)

* **Edition.** J. T. Humphries et al., "ghOSt: Fast & Flexible User-Space
  Delegation of Linux Scheduling", SOSP 2021, pp. 588-604, DOI
  10.1145/3477132.3483542: the PDF from
  <https://research.google/pubs/ghost-fast-and-flexible-user-space-delegation-of-linux-scheduling/>,
  17 pages, accessed 2026-10-29, read in full (`b/ghost-sosp21/`,
  `c37d636045a45e22`); `ghost-userspace` at commit `9ca0a1fb` (ABI 84,
  newer than the paper) read for the failure paths.
* **Mechanism.** User-space agents decide what runs on the CPUs of an
  enclave. The kernel posts messages (thread created, blocked, preempted,
  yielded, dead, woken, affinity changed, timer tick) into shared queues
  and keeps status words; agents commit decisions by system call, in groups
  and atomically. Every agent has a sequence number advanced per message
  and every thread another; a commit carrying a stale one fails with
  `ESTALE`. ghOSt runs below the default class, to which threads fall back
  when an agent crashes, and the kernel destroys an enclave whose agent has
  not scheduled a runnable thread within a configurable time.
* **Adopted.** A decision that names the state it observed and has no
  effect when that state changed: `erx_park` with its two epochs.
  Kernel-written status words as the trusted source of accounting. A
  kernel that enforces with deadlines while user code decides.
* **Rejected.** An agent deciding every switch; a message per lightweight
  process state change; agents trusted at the top priority; policy code at
  EL1; queues that can overflow (the code counts `ring->overflow`).
* **Numbers** (cited; Xeon 8173M at 2 GHz, Linux 4.15): message delivery
  725 ns to a local agent and 265 ns to the global agent; a local schedule
  888 ns; a remote schedule 1,772 ns end to end; a system call 72 ns; a
  pthread switch 410 ns; a CFS switch 599 ns; up to 1.5 million scheduled
  threads per second, 2.52 million grouped; a global loop of 30 µs left CPUs
  idle; the default of `runnable_timeout` was not found.

#### Syrup (2021)

* **Edition.** K. Kaffes, J. T. Humphries, D. Mazières and C. Kozyrakis,
  "Syrup: User-Defined Scheduling Across the Stack", SOSP 2021, DOI
  10.1145/3477132.3483548 (pages 605-620 per dblp, **unverified**): the
  author copy linked from
  <https://mast.stanford.edu/pubs/syrup_user_defined_scheduling_across_the_stack/>,
  16 pages, accessed 2026-10-29, read in full (`b/syrup-sosp21/`,
  `a7326ceee38fa114`).
* **Mechanism.** A policy is one function from an input to an executor,
  `PASS` or `DROP`, deployed into eBPF hooks or a ghOSt agent; a dispatcher
  confines each application's policy to its own inputs; shared maps are
  updated atomically; early binding causes head-of-line blocking.
* **Adopted.** Work summaries as small typed shared tables written with
  atomics (the control area); one trusted funnel that filters each party's
  inputs (the router); waking any idle executor late rather than binding a
  wakeup early (`erx_group_signal` with idle-first placement).
* **Rejected.** Policy code in the kernel; a user-space decision per input;
  access control by file permissions.
* **Numbers** (cited): policy cost under 2,000 cycles (1,563 to 1,709),
  mostly enforcement; a map access from user space 986 to 1,009 ns, about
  24 to 25 µs when offloaded to the NIC; MICA at a 1 ms p99.9 target 1.7 to
  1.8 million requests per second originally, 3.2 to 3.3 with hardware
  offload.

#### Linux `sched_ext`

* **Edition.** "Extensible Scheduler Class", the page at
  <https://cdn.kernel.org/doc/html/latest/scheduler/sched-ext.html>, whose
  header read 7.3.0 when saved on 2026-10-29 (`b/sched-ext-doc/`,
  `ac8f8a0f32f76b70`), read in full; the source at tag v7.3 (commit
  `c03c1a14`) read for the failure model. The URL's "latest" follows each
  release.
* **Mechanism.** A BPF scheduler dispatches through a global queue, a local
  queue per CPU and user queues, and "a CPU always executes a task from its
  local DSQ"; CPU selection is "not binding". "The default scheduling
  behavior is restored anytime an error is detected, a runnable task
  stalls, or on invoking the SysRq key sequence SysRq-S." The source shows
  a stall watchdog (at most 30 s) that blames whoever must drain a queue;
  ejection that claims the exit with a lock-free compare-and-swap and
  enters a bypass mode (FIFO, 5 ms slice, no mutexes) before taking any
  lock; a dispatch accepted only if its ownership brand still matches;
  and sub-schedulers (depth 4) whose per-CPU capabilities are "always a
  subset of its parent's", with revocation that cascades.
* **Adopted.** A kernel default that trusts nothing and needs no lock,
  entered before any recovery step that could block: with every group
  feature off, erXos's scheduler is plain round robin over threads, and
  quotas and grace timers bound what a runtime can do. Hints that never
  bind. Child limits that are subsets of the parent's (invariant S5).
* **Rejected.** BPF at EL1; delegates allowed to ignore configuration; a
  30 s ceiling; the rescue machinery, which exists because revocation
  strands tasks the kernel did not place.
* **Numbers** (cited from the source): default slice 20 ms; bypass slice
  5 ms; at most 32 dispatch loops; more than 256 re-enqueues ejects the
  scheduler. The documentation gives no latency figures.

### Language-native operating systems

#### JX (2002)

* **Edition.** M. Golm, M. Felser, C. Wawersich and J. Kleinöder, "The JX
  Operating System", USENIX ATC 2002, pp. 45-58:
  <https://usenix.org/legacy/publications/library/proceedings/usenix02/golm.html>
  and its PDF, accessed 2026-10-29, read in full (`b/jx-atc02/`,
  `9f03a6f0b30ec1ba`); Golm's dissertation (2002, chapters 4, 5.4 to 7
  read, `8b6ee60b97bf9e71`).
* **Mechanism.** A single address space with type-safe domains, each with
  its own heap, collector, threads and optional scheduler; portals are
  capabilities, and a call blocks the caller while a service thread runs.
  A global scheduler schedules domains and a domain's scheduler picks its
  threads, through events (preempted, blocked, unblocked), activations
  (`activated`, `switchTo` on a per-CPU portal) and queries (`portalCalled`
  asks whether to donate the slice). "The global scheduler does not need to
  trust a domain-local scheduler ... can not assume, that an invocation of
  the local scheduler returns"; `preempted()` runs with interrupts off under
  a verifier-checked bound. Domain ids are 64-bit and never reused.
* **Adopted.** The kernel waits for nothing a runtime does: preemption is a
  fact the runtime reads later. Sticky wake state. Identifiers never reused
  (domain ids). Asking whether to donate per call (charge words chosen by
  the runtime).
* **Rejected.** Isolation by verification alone; synchronous calls into
  the local scheduler; uninterruptible collector threads, which stalled NFS
  for about 100 ms; reference counts across domains, whose cycles go
  undetected.
* **Numbers** (cited; Pentium III at 500 MHz): IPC round trip 650 cycles
  (the dissertation gives 750), against L4Ka 818 and Fiasco 2,610 (on a
  450 MHz Pentium III); a portal call 920 to 960 cycles with one side's
  scheduler informed and 1,180 with both; domain creation 2,245 µs (Linux
  fork 263 µs); 35 KB per domain.

#### SPIN (1995)

* **Edition.** B. N. Bershad et al., "Extensibility, Safety and Performance
  in the SPIN Operating System", SOSP 1995, pp. 267-284:
  <https://cseweb.ucsd.edu/~savage/papers/Sosp95.pdf>, accessed 2026-10-29,
  read in full (`b/spin-sosp95/`, `9e1dbd98482c67ae`); the Strands report
  UW-CSE-97-09-01 as a supplement.
* **Mechanism.** Type-safe kernel extensions handle events. A strand has no
  kernel state beyond a name; the kernel raises Block and Unblock, and the
  thread package handles Checkpoint and Resume: "An application-specific
  scheduler presents itself to the global scheduler as a thread package."
  A handler invocation "affects at most one strand". Checkpoint and Resume
  run under the scheduler lock and are ephemeral, killed after a few ticks.
  Every upcall has a default handler.
* **Adopted.** Containment by construction: an event touches one group. A
  minimal runtime works with the defaults (`erx_fiber`). Plans validated
  whole before they are applied (the guardian's creation plans).
* **Rejected.** Schedulers inside the kernel and one collector shared by
  kernel and extensions.
* **Numbers** (cited; Alpha at 133 MHz): protected in-kernel call 0.13 µs;
  system call 4 µs (OSF/1 5, Mach 7); cross-address-space call 89 µs (Mach
  104, OSF/1 845). From the Strands report: CThreads fork-join 135 µs
  against 1,440 for pthreads; scheduler-activation upcalls 2.4 ms on the
  Firefly and up to 0.915 ms on Mach.

#### Singularity (2007)

* **Edition.** G. C. Hunt and J. R. Larus, "Singularity: Rethinking the
  Software Stack", ACM SIGOPS OSR 41(2), 2007, from the page at
  <https://www.microsoft.com/en-us/research/publication/singularity-rethinking-the-software-stack/>,
  accessed 2026-10-29, read in full (`b/singularity-osr07/`,
  `1da2c58082d7b285`); with Aiken et al., "Deconstructing Process
  Isolation" (MSPC 2006), Fähndrich et al. on channels (EuroSys 2006), and
  part of MSR-TR-2005-135.
* **Mechanism.** Sealed software-isolated processes, each with its own
  runtime and collector, exchange messages over typed channels whose data
  lives in an exchange heap with one owner per block. All threads are
  kernel threads; there is no second level. The default scheduler runs
  unblocked threads before preempted ones, and "threads from the unblocked
  list inherit the scheduling quantum of the thread that unblocked them". A
  thread inside the kernel counts as stopped for its process's collector;
  killing a process unwinds its frames.
* **Adopted.** Message-woken work may run first on the waker's resources:
  the receive boost and charge words. A thread blocked in the kernel is at
  a safe point. A process dies without its own cooperation, and others see
  the failure only when they receive. Several processes per hardware
  domain, by policy: several groups per domain.
* **Rejected.** Sealed processes, which exclude hot code loading; a kernel
  thread per process; enforcement by verification alone.
* **Numbers** (cited; Athlon 64 3000+ at 1.8 GHz, cycles): API call 80,
  thread yield 365, message ping-pong 1,040, process creation 388,000
  (Linux 437, 906, 5,800, 719,000); a switch between processes in "as few
  as 394 cycles"; the cost of hardware isolation on WebFiles +18.9% for a
  ring-0 separate domain, +33% in ring 3, +37.7% for three ring-3 domains.

#### Inferno (1997)

* **Edition.** S. Dorward et al., "The Inferno Operating System", Bell Labs
  Technical Journal 2(1), Winter 1997, pp. 5-18. The proposal's IEEE page
  (<https://ieeexplore.ieee.org/document/6772868/>) is paywalled; Vita
  Nuova's revised reprint was read in full (`b/inferno-bltj97/`,
  `7ae36a4378009833`) and not compared with the original, which was not
  obtained. Supplements: the Dis virtual machine paper, the Dis
  specification, and the `inferno-os` source at commit `36616fe5`.
  Accessed 2026-10-29.
* **Mechanism.** Each process has a namespace of file servers reached
  through Styx: "if the network resources are removed from an
  application's name space, then it is impossible for it to establish new
  network connections." From the source: one global run queue; a quantum
  of 2,048 Dis instructions (`PQUANTA`), checked on backward branches of
  JIT code; one host process runs Dis at a time, and `release` and
  `acquire` around blocking host calls start host processes on demand.
* **Adopted.** Quanta counted at safe points, the structure of BEAM's
  reductions. Blocking calls moved off the scheduler onto separate threads
  (workers, dirty I/O schedulers). A namespace as authority has its
  counterpart in imports and facets (design-domains.md).
* **Rejected.** A global VM lock; synchronous channels across domains.
* **Numbers** (cited): runs in "as little as 1 MB"; Dis JIT code "30-50%
  slower than native C".

## Related work

Sources beyond the proposal's list that the readers judged important, all
accessed 2026-10-29 and read in full unless stated. The sources of the
negative evidence are described under [Negative evidence](#negative-evidence),
and Fluke and Mach under [Kernel execution models](#kernel-execution-models).

### Virtual processors in Fiasco (2010)

* **Edition.** A. Lackorzynski, A. Warg and M. Peter, "Virtual Processors as
  Kernel Interface" (the PDF's title), Real-Time Linux Workshop 2010; the
  title "Generic Virtualization with Virtual Processors" and the venue are
  inferred from the file name and a citing paper (**unverified**).
  `os.inf.tu-dresden.de/papers_ps/rtlws2010_genericvirt.pdf`, 10 pages
  (`b/vcpu-rtlws10/`, `adfc6ae4bd81b941`). It is the primary source for
  the L4Re vCPU.
* **Findings.** "The microkernel can preempt the vCPU at any time
  irrespective of its event delivery status. However, if it finds the vCPU
  disabled, no upcalls will be generated and the execution will be resumed
  with the same state later"; an enabled vCPU "may resume its execution
  later with an upcall" (`rtlws2010_genericvirt.txt:284-301`)
  *(checked)*. Transparent preemption makes "grab the lock" and "announce
  ownership" non-atomic, so a contender cannot donate to the owner. The
  paper also states the idea of a runtime group: "assign the two threads
  different priorities but feed them from one budget ... we do not know of
  any microkernel that offers such functionality. It is not apparent if
  such a scheme would be compatible with other objectives, such as time
  donation along IPC dependency chains" (229-240) *(checked)*. erXos's
  groups with call donation are that combination; E-S5 and E-S8 test it.
* **Numbers** (cited; AMD Phenom X3 8450 at 2.1 GHz, cycles for Linux host,
  Fiasco with IPC and Fiasco with vCPUs): exception within an address space
  2,104, 1,594, 870; across address spaces 7,456, 2,433, 1,663; page fault
  with mapping 19,833, 3,751, 2,833. A thread switch costs 51 cycles at user
  level and 335 through the kernel. A Linux build took 161.5 s with
  threads and 158.8 s with vCPUs.

### Donation and helping in the Dresden kernels (2001 to 2010)

* **Editions.** U. Steinberg, J. Wolter and H. Härtig, "Fast Component
  Interaction for Real-Time Systems" (Credo), ECRTS 2005, pp. 89-97
  (`b/steinberg-ecrts05/`, `56466d783134aef8`); U. Steinberg, A. Böttcher and
  B. Kauer, "Timeslice Donation in Component-Based Systems", OSPERT 2010
  (NOVA, `b/steinberg-ospert10/`, `755f63c329a3ac4b`); M. Hohmuth and
  H. Härtig, "Pragmatic nonblocking synchronization for real-time systems",
  USENIX ATC 2001 (Fiasco's helping locks, `b/hohmuth-usenix01/`,
  `9898256bed4312a9`).
* **Findings.** Credo splits a thread into an execution context and a
  scheduling context and switches only the first on a call, so "the
  consumed CPU time is always accounted to the client requesting a
  service"; resuming donations after preemption needed per-node caches,
  because walking chains failed on trees and dead ends; and when a budget
  expires in a critical section "the kernel does not know anything about
  critical regions". NOVA refuses cross-CPU helping, since time would
  "disappear on one processor and ... reappear on another", makes chain
  traversal preemptible and charges it to the selecting timeslice, and
  warns that a malicious user can build "a long donation or helping chain".
  Hohmuth and Härtig describe Fiasco's thread descriptors as containing "a
  kernel stack, areas for saving CPU registers" (`hohmuth.txt:380-385`)
  *(checked)*, a kernel built so that "critical sections never need to
  sleep", and helping locks in which a contender lends its CPU to the
  holder.
* **Taken.** Call donation fixed at delivery and held until the reply, so no
  chain is walked at a decision (design-scheduler.md, Call donation). No
  donation across CPUs. Helping is not used in erXos's kernel, which is not
  preemptible.
* **Numbers** (cited): Credo's `donate_time` is 16 instructions and an IPC
  about 1,380 cycles on a 500 MHz Pentium III; NOVA's traversal costs under
  about 300 cycles per link (reading) and breaking a link under 5 µs for 64
  threads and 8 µs for 512 on a 2.67 GHz Core 2 Duo, with no call depth over
  16 observed; Fiasco's thread lock 245 cycles and IPC 653 and 810 cycles on
  a Pentium 133 and a Pentium II 400.

### Temporal capabilities, Slite and thread migration in Composite

* **Editions.** P. K. Gadepalli, R. Gifford, L. Baier, M. Kelly and
  G. Parmer, "Temporal Capabilities: Access Control for Time", RTSS 2017
  (`b/tcaps-rtss17/`, `e78d5938819923a2`); P. K. Gadepalli, G. Pan and
  G. Parmer, "Slite: OS Support for Near Zero-Cost, Configurable
  Scheduling", RTAS 2020 (`b/slite-rtas20/`, `f5162d4be3932327`), with the
  Composite source at `d3b9d9f2`; G. Parmer, "The Case for Thread
  Migration: Predictable IPC in a Customizable and Reliable OS", OSPERT
  2010 (`b/parmer-ospert10/`, `16cd6d329d2361d9`).
* **Findings.** A temporal capability is a budget in cycles that the system
  does not replenish, delegable over asynchronous endpoints, with a
  "quality" vector that only degrades when merged; it is per core and
  cannot be revoked. Its cosDist example runs driver work and interrupts on
  the client's time, which is the precedent for a signal that carries its
  donor (design-scheduler.md, Risks and open questions). Slite lets user
  level dispatch threads of one domain with a decision token that the
  kernel refuses while events are pending ("41 cycles (13 nanoseconds)").
  Parmer argues that calls on the caller's thread keep accounting with the
  client and that lazy switching makes the charged thread unpredictable.
* **Taken.** Finite donations whose rights only shrink (donated groups are
  children of the client's group); a decision refused when the state it
  observed has changed (`erx_park`).
* **Numbers** (cited): temporal capabilities on a 2.8 GHz Core i7-2600S, in
  average and worst-case cycles: IPC round trip 787 and 3,664, switch 365
  and 2,708, delegation 786 and 7,480; a switch without timer reprogramming
  "almost 70% faster", and programming the HPET over 10 µs against 100 to
  400 cycles for the LAPIC; Slite on a 3.2 GHz i7-8700: user-level dispatch
  41 cycles against about 260 in Composite's kernel and about 1,600 in Linux
  RT (reading).

### Concord and Shinjuku (2019, 2023)

* **Editions.** R. Iyer, M. Unal, M. Kogias and G. Candea, "Achieving
  Microsecond-Scale Tail Latency Efficiently with Approximate Optimal
  Scheduling" (Concord), SOSP 2023, pp. 466-481 (`b/concord-sosp23/`,
  `74a59e9166bb1011`); K. Kaffes et al., "Shinjuku: Preemptive Scheduling
  for µsecond-scale Tail Latency", NSDI 2019, pp. 345-360
  (`b/shinjuku-nsdi19/`, `b6196642b99a21e6`).
* **Findings.** Concord preempts cooperatively: the dispatcher writes a
  worker's cache line at the end of a quantum, and compiler-inserted probes
  poll it; it never preempts inside external code or while an application
  lock is held. Shinjuku preempts every 5 to 15 µs with posted interrupts
  and protects critical sections without bound.
* **Taken.** A request to yield that the runtime polls where it already
  checks (`yield_req`, read when `defer` returns to zero, and ERTS's
  reduction checks: `CONTEXT_REDS` is 4,000 in `erl_vm.h:53`), with a
  deadline after which the kernel preempts anyway.
* **Numbers** (cited; Xeon 6142 at 2.6 GHz and E5-2658 at 2.3 GHz): an IPI in
  Shinjuku costs about 1,200 cycles, "an ≈ 12% overhead for q = 5µs, and an ≈
  30% overhead for q = 2µs, assuming a 2GHz clock"; Concord's instrumentation
  costs 1 to 1.5% and its notification is "16× cheaper" than reading the
  time-stamp counter, and the two overheads "become roughly equal (≈ 0.7%) at
  around 25µs" of quantum (`concord-sosp23.txt:245, 415-424`) *(checked)*;
  Shinjuku's Table 1, sender, receiver and total cycles: Linux signal 2,084,
  2,523, 4,950; IPI 2,081, 2,662, 4,219; IPI without exits 298, 1,212, 1,993;
  `swapcontext` 985 cycles, 140 without the signal mask.

### Tessellation (2009 to 2014)

* **Editions.** R. Liu et al., HotPar 2009 (`5d70c0de3fdf1146`);
  J. A. Colmenares et al., DAC 2013 (`328965d4c222d33d`), both read in
  full; Eads et al., UCB/EECS-2014-137 (`b6bb6b4e7648352a`), sections 2 to
  5 and 6.1.
* **Findings.** Cells are performance-isolated resource containers
  scheduled at two levels, with a small menu of types (dedicated, EDF, CBS,
  best effort with a small reservation). A user-level broker holds the only
  call that changes allocations and swaps validated, double-buffered plans
  at a synchronised time. The PULSE runtime is preempted by a kernel that
  "saves the context of the interrupted task to userspace and clears an
  atomically accessible, user-writable TICKS_ENABLED flag"
  (`EECS-2014-137.raw.txt:799-801`); "application schedulers never block".
* **Taken.** Policy through one privileged capability (`CONFIGURE`) and
  plans validated whole before they are applied.
* **Numbers** (cited; Core i5-3550 at 3.3 GHz): a kernel switch 1,452 ns plus
  a user-level switch 1,598 ns; redistribution under 2 ms; a GUI service
  missed 0.1% of 60 fps deadlines against 65% for Nano-X on Linux.

### Hierarchical start-time fair queuing (1996)

* **Edition.** P. Goyal, X. Guo and H. M. Vin, "A Hierarchical CPU
  Scheduler for Multimedia Operating Systems", OSDI 1996, pp. 107-122: the
  USENIX HTML version (`a/hsfq/index.html`, `2c9ffc0f4a34e476`), with its
  formula images.
* **Findings.** A weighted tree with start-time fair queuing at internal
  nodes and any scheduler at the leaves. A leaf tells the tree only that it
  became runnable, that its last thread slept, and how long it ran, after
  the fact. Fairness holds "regardless of fluctuations in available
  processor bandwidth", and a node's delay bound grows with the sum of its
  siblings' maximum quanta. Priority inversion across classes is left
  unsolved.
* **Taken and not taken.** The leaf interface is what erXos's kernel knows
  about a group: whether its executors are parked, and what they used. A
  runtime that claims to be runnable while spinning pays for it in quota
  (inferred: in SFQ it pays in virtual time). Weighted sharing within a
  level was rejected for simplicity (design-scheduler.md, Alternatives).
  The delay bound's dependence on the longest quantum is why time to a safe
  point matters (E-S3).
* **Numbers** (cited; SPARCstation 10, Solaris 2.4): throughput within 1% of
  the unmodified kernel; depths 0 to 30 within 0.2%; weights 2 : 6 gave a
  1 : 3 throughput ratio.

### Resource containers (1999)

* **Edition.** G. Banga, P. Druschel and J. C. Mogul, "Resource Containers:
  A New Facility for Resource Management in Server Systems", OSDI 1999
  (`a/rescontainers/banga.pdf`, `16d5319ada401f0a`).
* **Findings.** The resource principal is separated from the protection
  domain: an application binds its thread to a container per request, the
  kernel infers a scheduler binding from recent service, and containers
  form a hierarchy and pass between processes as descriptors. "A practical
  implementation would require an access control model for containers" was
  left undone (`banga.raw.txt:451-453`).
* **Taken.** Charge words: a runtime names the donated group of the client
  it serves, and the access control the paper left out is the `CHARGE`
  right on a handle the client's policy created.
* **Numbers** (cited; 500 MHz Alpha 21164, Digital UNIX 4.0D): create
  2.36 µs, change a thread's binding 1.04 µs, move between processes
  3.15 µs; caps of 30% and 10% on CGI work "enforced almost exactly" but
  only over tens of seconds; about 73% of peak throughput kept under 70,000
  SYNs per second, against none without containers.

### Core allocation: Arachne, Shenango and Caladan (2018 to 2020)

* **Editions.** H. Qin et al., "Arachne: Core-Aware Thread Management", OSDI
  2018, pp. 145-160 (`a/arachne/`, `329726d9bef9486a`); A. Ousterhout et al.,
  "Shenango", NSDI 2019 (`6e6a97e0a17a6f33`); J. Fried et al., "Caladan",
  OSDI 2020 (`5db4e5f2548cf125`).
* **Findings.** Arachne's arbiter asks a runtime to release a core, because
  "the core's kernel thread might be in an inconvenient state (e.g. it might
  have acquired an important spin lock)", and demotes it by force after a
  period "currently 10 ms" (`osdi18-qin` raw text 392-432) *(checked)*;
  without the arbiter, user threads were "stranded ... for many
  milliseconds" when Linux descheduled their kernel thread. Shenango
  re-checks congestion every 5 µs and finds "duration of queuing is a more
  robust signal than the length of a queue". Caladan reacts every 10 µs,
  warns "a few microseconds" before preemption, and states that a scheduler
  must react within 2X to bound latency growth to X.
* **Taken and not taken.** Revocation as notice, bounded grace, then
  preemption of the whole executor: deferred preemption. Dedicated arbiter
  cores and microsecond core reallocation were rejected for erXos's scale
  (design-scheduler.md, Alternatives).
* **Numbers** (cited): Arachne acquires a core in 29 µs, about 80% of it in
  sockets; Shenango reallocates a core in 5.9 µs; Caladan cut a tail during
  garbage collection "from 580 ms to 52 µs".

### Further sources

* K. Klues, "OS and Runtime Support for Efficiently Managing Cores in
  Parallel Applications", UCB/EECS-2015-188, 13 August 2015, 139 pages
  (`a/akaros-klues-thesis/`, `31c1161a4275d299`): sections 1.2-1.3,
  2.1-2.3.2 and chapters 3 and 4 read. Pan's PLDI paper and Klues's
  section 3.4.1 describe the composition of SPQR differently; Pan is taken
  as primary.
* Erlang/OTP 29.1.2: `erts/doc/references/erl_cmd.md` (`+S` defaults to the
  number of logical processors configured and limits schedulers online
  under a detected CPU quota, 897-905; binding schedulers when other
  processes also bind "can sometimes be severe", 1066-1073) *(checked)*;
  `erl_process.c` (the sleep protocol, 3086-3117); and thread progress as
  read in `~/erxos-scratch/draft/research-results/a5d3e7413a9be87a0-erts-thread-progress-tsd-os.md`
  (2026-10-29): sleeping managed threads count as having confirmed progress
  (`erl_thr_progress.c:61-65`), and normal schedulers confirm between
  processes (`erl_process.c:9857-9866`).

## Kernel-runtime interfaces

The proposal requires that "the runtime must preserve an interrupted
continuation until a safe point", and that "timer preemption must not
recursively invoke ERTS during GC or a critical section". Every interface
below answers two questions: where an interrupted continuation goes, and
what keeps the runtime from being entered while it is inside its scheduler,
its collector or a critical section.

| System | The interrupted continuation | Entry during a critical section is avoided by | Events while the runtime is busy | Lost-wakeup guard |
| --- | --- | --- | --- | --- |
| Psyche | the kernel resumes the VP in place | masking software interrupts; a warning before the quantum ends | queued by importance behind a "queued" flag, drained by a call | the queued flag |
| Scheduler activations | saved by the kernel and handed to the runtime by an upcall on a new activation; never resumed directly | recovery: the upcall finishes the preempted critical section in a copy | combined into one upcall | as many running activations as processors |
| Nemesis | resume slot while the activation bit is clear; activation slot and an upcall while it is set | clearing the bit around critical sections; `rfa()` re-enables and switches atomically | event counts and a FIFO of endpoint indices | counts "never lose events" |
| Barrelfish | resumed in place from the disabled area when disabled or inside the critical PC range; else the enabled area and a Run upcall | the `disabled` word and the PC range | delivery counters and `haswork` | the yield predicate |
| L4Re vCPU (Fiasco `50bbe8a9`) | resumed in place: an expired slice only requeues the thread | events disabled in the state word | a sticky pending flag, checked on enable | the pending flag |
| Akaros | the vcore context restarts where it stopped while notifications are disabled; else the user-thread context is saved and a notification raised | `notif_disabled` | `notif_pending` and mailboxes | "yield can fail" |
| Lithe | no preemption between runtimes; the operating system's preemption of the underlying threads is not handled (`lithe-pldi2010.raw.txt:583-590`) | cooperation | not applicable | `unblock` records and never resumes |
| Converse | no preemption | handlers run to completion | not applicable | a wake only when "acceptable" (p. 25) *(checked)* |
| Tessellation PULSE | saved to user space with `TICKS_ENABLED` cleared; interrupted scheduler contexts finish before continuations are handed over | the flag | an adaptation flag | persistent endpoints |
| erXos | always resumed in place; no runtime code runs at a preemption (invariant S1) | nothing to avoid: the kernel has no entry point into a runtime; a `defer` count postpones slice-end and quota preemption by a bounded grace | bits ORed into the control area's `events` word | `erx_park` compares the group and slot epochs under the park lock (invariant S2) |

**What the systems share.** Whenever a runtime cannot accept control, its
continuation stays where the kernel saved it; the runtime learns of events
through state it reads when it chooses; and a park or yield checks that
state and fails if it changed. **Where they differ** is whether the runtime
is ever entered asynchronously. Psyche, scheduler activations, Nemesis,
Barrelfish, the vCPU and Akaros all enter it, and each needs machinery so
that the entry never lands inside a critical section: a mask, a recovery
scheme, a bit with two slots, a PC range, or a disabled flag. erXos removes
the asynchronous entry, so the proposal's requirement holds by construction
and none of that machinery exists. The price is that a runtime learns of a
preemption only from its status words, and an event for a busy runtime
waits for its next safe point (experiment X5 below).

**Why ERTS needs no upcall.** ERTS switches processes only at reduction
checks, so the registers of an interrupted scheduler are of no use to it.
Its executors never block outside their domain, so "activation blocked"
cannot happen. What remains to tell it (wakeups, inbox records, capacity
changes, yield requests) is level-valued and fits in words it reads at its
safe points; ERTS already sleeps with a compare-and-swap protocol on its
scheduler flags (`erl_process.c:3086-3117`).

**What upcalls cost.** A vCPU round trip costs 140 ns on the M4 under HVF,
about 4.5 times a trap with an address-space switch (31 ns), both measured
([Fiasco under HVF](#fiasco-under-hvf)). Vectoring every preemption to a
user-level scheduler cost 1.4 to 2.1 µs per level on a 3 GHz Pentium D
(Stoess), and scheduler activations' prototype took 2.4 ms per kernel
signal-wait on the Firefly. A polled word cost Concord 1 to 1.5% where
interrupt-driven preemption cost Shinjuku about 12% at a 5 µs quantum, and
the two are roughly equal at about 25 µs (x86, cited). erXos's slices are
milliseconds, so its case for polled requests is safety, not cost
(inferred).

**Shared pages are an attack surface.** Barrelfish's kernel, as read by
helper B, restores state from user-writable memory, double-fetches `SPSR`
and asserts on re-read shared words. Akaros's rules are "I never have the
kernel operate in a loop controlled completely by the user" and "any
kernel locking strategy needs to use memory that is not user-writable"
(`EECS-2014-223.txt:3057-3058, 4344`) *(checked)*. erXos keeps saved
registers in kernel memory, reads the runtime-written words (urgency,
`defer`, charge) once per decision through its shared-area accessors, and
validates every value it loads (design-kernel.md, invariant K7).

**Faults inside the runtime's critical code** are undefined in Nemesis, kill
the process in Akaros, and make a Barrelfish domain unrunnable after two.
erXos commits memory before use and never pages to storage, so a fault the
kernel cannot resolve from a reserve ends the domain
(design-scheduler.md, Executor class enforcement).

**Taken.** Resume in place for every preemption; level-valued events read at
safe points; a park that fails when the state it observed has changed;
kernel-written status words (Psyche's magic page, Akaros's read-only page,
Barrelfish's published running dispatcher); no interrupt for a running
receiver (TN-009). **Rejected.** Every form of upcall: scheduler
activations' upcalls with state, Nemesis' activation bit and slots,
Barrelfish's Run upcall and PC range, vCPU event upcalls, Akaros's
notification upcalls and its event-delivery option matrix.

## Hierarchy and flattening

The proposal asks for "one CPU-resource authority with composable
second-level schedulers". The sources fall into three families:
hierarchies of schedulers, one kernel scheduler with several budgets per
client ("flattening"), and accounting principals.

| Source | Shape | Enforced by | Cost (platform) |
| --- | --- | --- | --- |
| Stoess 2007 | user-level schedulers; preemption IPC up the hierarchy | the scheduler threads; no kernel budgets | 1.4 to 2.1 µs per level; 7.8% at a 2 ms tick (Pentium D 3 GHz) |
| CPU inheritance 1996 | scheduler threads donate the CPU | the donating threads | dispatch 8.0 µs at the root, 24.4 µs at 8 levels (Pentium 100 MHz) |
| HSFQ 1996 | weighted SFQ tree in the kernel, any leaf scheduler | the kernel | depths 0 to 30 within 0.2% of throughput (SPARCstation 10) |
| Composite 2008 | scheduler components; kernel accounting | the components | thread switch 529 cycles, 688 through a scheduler, 976 with accounting (Pentium 4) |
| Flattening 2012 | several scheduling contexts per vCPU, switched by the guest | kernel budgets at global priorities | 795 cycles paravirtualised, 5,863 fully virtualised, per switch (Phenom 2.1 GHz) |
| Scheduling constraints 2026 | conjunctive objects attached to threads | the kernel | +32 to 37 cycles per context switch with one constraint, 1,070 cycles at eight (Cortex-A72, readings) |
| seL4 MCS 2018 | capabilities with sporadic budgets; donation to passive servers | the kernel | schedule +38 to 45%, call +1 to 21% |
| Temporal capabilities 2017 | non-replenished, delegable budgets with quality vectors | the kernel | delegation 786 cycles average (Core i7 2.8 GHz) |
| Resource containers 1999 | principals apart from domains; bindings | the kernel, over seconds | rebinding 1.04 µs (Alpha 500 MHz) |
| Nemesis 1995-1996 | Atropos per scheduling domain; services in the client | the kernel's EDF | reschedule 1.37 µs (Alpha 21064) |
| erXos | one kernel scheduler over a tree of groups whose quotas, cpusets and ceilings are intersected along the path; bands as child groups | the kernel, at every decision, at every level | a path walk of at most eight groups; a budget of 150 ns per pick or enqueue with a path of four, and an estimate of 30 to 80 ns per pick |

**A hierarchy of limits, not of schedulers.** Hierarchies of schedulers pay
per level and per event and leave isolation to the schedulers' honesty
(Stoess, CPU inheritance). erXos's tree is a hierarchy of limits evaluated
by one scheduler, the same flattening that the scheduling constraints
perform with conjunction: every group on a payer's path is charged and
checked (invariants S4 and S5). The only second level is the runtime, and
the kernel never calls it. seL4's objection that hierarchical delegation
suffers "algorithmic utilisation loss" concerns nested reservations with
guarantees; erXos's quotas are caps without admission control, so the
objection applies only if guaranteed reservations are ever added
(inferred).

**Bands.** Lackorzyński et al. show task sets that no single budget per
client can schedule and that several budgets at different global
priorities can. erXos realises this as child groups of a runtime's group,
one per band, named in the executor's charge word (design-scheduler.md,
Charge words). The priority stays apart from the budget, as both the
scheduling constraints and seL4 keep it.

**Accounting on behalf of others.**

* *Synchronous calls.* The donor pays: CPU inheritance ("charging T1 rather
  than T0 would allow the accounting system to be subverted"), Credo, seL4's
  passive servers, Parmer's thread migration. Stock Fiasco's donation lapses
  at the next scheduling decision (`context.cpp:1148-1163`); erXos fixes
  the server's payer when the call is delivered and holds it until the
  reply.
* *Asynchronous work.* Resource Containers rebind a thread to the client's
  principal per request, with no access control; temporal capabilities
  carry finite slices with requests. erXos's charge words name a donated
  group that the client's policy carved from the client's grant and handed
  over with only the `CHARGE` right.
* *Per-client bindings in servers.* Nemesis lets a server attach QoS
  parameters per binding (`TR376.utf8.txt:3543-3555`); erXos creates one
  donated group per binding.

**When the payer runs out.** erXos lets a server whose caller's payer is
exhausted continue on its own grant and counts the fallback; a charge word
that names an exhausted group falls back the same way (design-scheduler.md,
Payer and urgency resolution). Lyons et al. criticise exactly this in L4
timeslice donation ("the server will run on its own time slice"), and
bandwidth inheritance for the opposite reason ("make the waiting client
pay for another client's contract violation"). Their answer is a timeout
fault to a handler, which costs 1.13 to 23.3 µs depending on the action
and platform (cited). How much a client can make a server spend this way
(inferred from the design's rules): the fallback is resolved at every
decision, so it ends when the client's next period begins; meanwhile the
client's own threads are throttled, and each has at most one call
outstanding. Per period the server spends on the client's behalf at most
the work of those outstanding calls, and at most the rest of the period on
each server thread that serves one. For charge words the bound is what the
grant's ingress allowance admits (design-domains.md, Facets). Experiment
X2 measures it.

**Several CPUs.** A budget shared by several CPUs is unsolved in the L4
family as read: seL4 and temporal capabilities are per core, NOVA refuses
donation across CPUs, and the scheduling-constraints artifact arms one
timer per budget. erXos keeps one pool per period and lets each CPU draw
local slices of at most 1 ms, so a group's usage per period exceeds its
quota by at most one draw quantum per CPU (invariant S4). Linux's CFS
bandwidth control is a similar design, but it was not read for this record
(**unverified**).

**Replenishment.** erXos refills a group's pool once per period, at the first
draw after the period begins, and carries debts forward. seL4 uses sporadic
servers, and the scheduling constraints offer a deferrable server. A budget
refilled at period boundaries can be spent at the end of one period and again
at the start of the next, so a window of one period that straddles a boundary
can hold twice the quota (inferred from the design's rules); invariant S4
bounds only aligned periods. Experiment X3 measures what a victim sees.

**Taken.** Conjunctive caps along the path (scheduling constraints);
admission and grant changes held by the policy (seL4, Tessellation);
donor-pays call donation held until the reply (CPU inheritance, Credo,
seL4); capability-held charge handles (Resource Containers with the access
control they lacked); bands (flattening); per-CPU accounting (seL4).
**Rejected.** User-level scheduler hierarchies with an event per level
(Stoess, CPU inheritance); weights (HSFQ) and deadlines (Atropos, seL4)
until an experiment shows quotas and round robin within a level fall short
(design-scheduler.md, Alternatives considered); importing the
scheduling-constraints artifact.

## Lock-holder preemption

When the kernel preempts an executor that holds one of its runtime's locks,
the runtime's other executors spin or wait for a thread that is not
running. Every two-level system read meets this problem.

| Approach | Source | Bound on the delay | What remains |
| --- | --- | --- | --- |
| a warning before the quantum ends | Psyche: 3 ms of a 100 ms quantum in the experiment | set by the user up to a kernel maximum | best effort: "inopportune preemption is still possible" |
| recovery: finish the preempted critical section | scheduler activations; NetBSD; Mach | until the section ends | a descriptor update in every spinlock operation "undesirably adds overhead in the common case" (`williams.raw.txt:640-647`); two stopped contexts can deadlock (Rhoden) |
| a "don't preempt me" flag with a "you owe me" reply | Solaris since 2.6 (`schedctl`) | not stated in the white paper | the holder must yield when told, or lose the privilege |
| a time-slice extension | Linux `rseq` | default and minimum 5 µs, at most 50 µs, enforced by a timer | raising the default "can/will affect the minimum scheduling latency" |
| cooperative release, then force | Arachne | 10 ms | stranded threads without the arbiter |
| a deferral counter over scheduler, RCU and spinlocks | Shenango | not stated | "A malicious kthread could refuse to park" is not mitigated |
| a warning a few microseconds ahead | Caladan | a few µs | not stated |
| no preemption while an application lock is held | Concord | a lock counter | trusts cooperation |
| locks that advertise their holder, and a directed switch to it | Akaros | not applicable | about 16 cycles more per lock |
| a request for slack inside a critical section; gang scheduling | Barrelfish (HotPar 2010) | not stated | not measured for lock holders |
| restartable sequences and helping | Composite | not applicable | no atomicity across CPUs |
| deferred preemption | erXos | a grace of 50 µs by default, clamped to 5 to 1,000 µs, only for slice ends and quota exhaustion; overruns counted and repaid from the next period | urgency preemption stays immediate; collection and NIFs are not deferred sections |

**The evidence for mitigation.** Under periodic 10 ms preemption of two
vcores, plain MCS lock throughput fell to 0 and holder-aware locks kept
about 250 locks per ms (Akaros, Xeon). Psyche's warning cut completion from
40.1 to 16.0 s at multiprogramming level 2 and from 61.6 to 23.8 s at level
3, and helped only once work generation was decentralised. Oblivious
time-slicing stranded Arachne's user threads for milliseconds.

**erXos's choice** follows Solaris and Linux: a count the runtime raises
around its critical sections, a yield request, and a grace bounded by a
kernel timer. It needs no recovery code and costs the runtime two stores and
a load per critical section (design-runtime.md, Performance, an estimate).
The default grace is Linux's maximum, 50 µs, on the estimate that ERTS's
critical sections are longer than those Linux's extension targets. Linux's
own default is 5 µs, which is also its minimum, and its documentation asks
that "any proposed changes to this default ... come with a selftest and
rseq-slice-hist.py output that shows the new value has merrit"
(`linux-mainline-syscalls/rseq.rst`) *(checked)*. No source read measures
how long ERTS holds its run-queue, process or carrier locks; E-S3 does.
Two limits follow from the design (inferred): a wake of a more urgent
thread (the router, a driver) still preempts a lock holder at once, and
status words are what let the other executors avoid spinning on it
(experiment X6).

## Negative evidence

| System | What was abandoned, and when | Stated reasons | What survived |
| --- | --- | --- | --- |
| NetBSD | scheduler activations in `libpthread`, replaced by 1:1 when the newlock2 branch merged on 2007-02-09, which "replaces the existing SA threads model with a 1:1 threading model" (`changes-5.0.html:789`), first released in 5.0 *(checked)* | "The SA implementation was complicated, scaled poorly on multiprocessor systems and had no support for real-time applications" (Rasiukevicius, 4 May 2009, `netbsd_5_scheduling_apis.raw.txt:12-13`) *(checked)*; SA "restricts any instance of a threaded application to a single CPU" (Doran, `netbsd-newlock2-mail/0001.html:30-39`) | a compatibility layer: the 5.0 changes add "compatibility support for the Scheduler Activations" and builds for NetBSD 2, 3 and 4 chroots *(checked)* |
| FreeBSD | KSE and `libkse`: `libthr` became the default in 7.0 (announced 27 February 2008) and kernel KSE was removed on 2008-03-12 (`UPDATING` entry 20080312) *(checked)* | "the M:N approach taken by the kse library was never developed to its full potential" (Roberson's commit 6617724c5fb1); 1:1 is "Easier to write, easier to maintain, easier to understand, easier to debug, and *good enough*", while KSE threads "are almost certainly more efficient at runtime, but we've got to get to the 'running' point first" (Wemm, freebsd-arch, 3 April 2003) *(checked)* | nothing |
| Solaris | the M:N library: Solaris 8 added an alternate 1:1 library and Solaris 9 made 1:1 the default (white paper, ©2004 Sun) | "The 1:1 implementation was simpler to develop, and its code paths were generally more efficient"; of the two-tier advantages, user-level synchronisation "has proven to be significant, but the second advantage has not. Building a user-level scheduler that works well in tandem with the kernel's scheduler is a significant challenge" (raw text 349-359) *(checked)* | preemption control |
| Windows | user-mode scheduling: "As of Windows 11, user-mode scheduling is not supported", and it "is not available on Arm64" (`user-mode-scheduling.md:12, 19`) *(checked)*; Microsoft's own Concurrency Runtime stopped using it in Visual Studio 2013 (`concurrency-namespace-enums.md:229`) *(checked)* | none found in a primary source | nothing |
| Linux UMCG and SwitchTo | never merged: the mainline v7.3 system-call table has no such call (`syscall_64.tbl`) | Zijlstra: "these patches do *NOT* support the very thing this all started with, namely block + wakeup notifications ... the whole uaccess stuff is horrific" *(checked)*; Turner (LPC 2013): operations "must be commutative", "Requiring a re-entrant (asynchronous) user-scheduler entry classically hard; prefer a synchronous programming model" *(checked)* | `rseq` time-slice extension; Google's fibers use only cooperative features |
| Linux NPTL | the M:N candidates, in favour of 1:1 (Drepper and Molnar, 21 February 2005) | two schedulers that do not collaborate; register copying too costly; the O(1) scheduler made the motivation moot; signals "hard, a lot of code" (`nptl-design.raw.txt:238-251`) *(checked)* | starting and stopping 100,000 threads fell from 15 minutes to 2 s (520) |

**Stated against inferred.** The quotations above are the reasons the
implementers gave. Williams adds, for NetBSD, that N:M systems "are more
complicated than either of the other models, and can be more difficult to
develop, debug, and use effectively" (`williams.raw.txt:136-147`), that a
spare LWP had to be "pre-allocated and cached" so that a blocking upcall
could not recurse into the sleep path (562-566), and that POSIX signals
needed their own cooperation between kernel and library (352-367)
*(checked)*. `kse(2)` states the race that two schedulers create: the
switch of `km_curthread` "must be atomic with the loading of the context
of the new thread" (the FreeBSD 7.2 manual page,
`freebsd-kse-man/kse.2-7.2.html`) *(checked)*. The common factor is
inferred, not stated: every abandoned system was a general-purpose thread
library for arbitrary C code (POSIX threads, or Win32 threads in Windows),
whose kernel and library jointly owned each thread's state and blocking,
and for POSIX its signals. The NetBSD 5.0 announcement credits its gains
to the 1:1 library together with "new kernel synchronization primitives,
kernel preemption, a rewritten scheduler implementation" *(checked)*, so
no abandonment was an isolated comparison of M:N and 1:1. The scheduler
activations prototype took 2.4 ms per kernel signal-wait, and no source
read reports a measured win of cheap user-level switching large enough to
outweigh the complexity: Solaris found it "hard to support the idea that
user-level context switching is orders of magnitude faster than going via
the kernel" (raw text 1133) *(checked)*, and Klues found Lithe beat the
best static tuning by 2.3 to 10%.

**Why erXos's situation differs.** ERTS is one trusted runtime that already
multiplexes millions of processes over a few threads and scales on SMP; its
processes have no POSIX identity, signals or per-thread priority; it
switches only at reduction-counted safe points; and erXos's executors are
ordinary threads that are never entered asynchronously and never block
outside their domain. That removes the upcall re-entrancy, the replacement
activations, the signal layer and the joint ownership of thread state that
the implementers name.

**What still applies.** Lock-holder preemption
([Lock-holder preemption](#lock-holder-preemption)). Choosing how many
executors to run (Solaris, Arachne): capacity advice. Observability: Turner
argued for 1:1 partly because tools can see every thread, so the inspector
must show lightweight processes as first-class. A contract that grows:
keep it small and its state machines checked exhaustively. Foreign runtimes
resist: Akaros's Go port took 1.5 years and kept a pthread emulation layer,
which matters when erXos hosts runtimes other than ERTS.

## Identity and lifecycle

The proposal states the requirement in three sentences, quoted verbatim
from its v0.2 text:

* "Logical process: global, generation-safe identity, owner domain,
  lifecycle/supervisor, messaging endpoint and resource attribution."
* "The common PID/anchor registry belongs to trusted erXos services, backed
  by kernel domain/native-object identities, without a kernel TCB or
  syscall for every lightweight spawn. PID ranges and lifecycle events can
  be delegated and batched. PIDs express identity; capabilities
  independently express authority."
* "An Erlang resource manager allocates policy-level rights and budgets; a
  small guardian retains the authority to restart the system runtime and
  reclaim domains."

| Source | What names a process | What grants authority over it | What happens when its holder dies |
| --- | --- | --- | --- |
| Psyche | a name the VP writes into shared memory; "new processes can be created simply by inventing new names"; the kernel tracks only call chains across domains | probabilistic keys (rejected for erXos) | a trap that claims a departed process is an error |
| Resource containers | the protection domain names the process; a separate container names the principal that pays | holding the container's descriptor; no access-control model ("space does not permit a discussion") | not addressed |
| Singularity | a sealed process | channel endpoints, owned by one process at a time | killed without its cooperation; its frames are unwound; exchange-heap blocks record their owner and are reclaimed in the background; peers see the failure when they receive |
| JX | 64-bit domain ids never reused, checked with the pointer | portals | aborting a call sets a flag the service checks at a safe point; reference counts across domains miss cycles |
| SPIN | a strand has no kernel state beyond its name | type-safe guards on handlers | default handlers |
| Inferno | a process with its own namespace | the namespace: what is not in it cannot be reached | not addressed |
| Akaros | a many-core process with vcores; no kernel thread per user thread | not covered by the extracts | not covered by the extracts, except that a hard page fault in vcore context kills the whole process |
| Tessellation | a cell, a performance-isolated container | the allocation broker's one privileged call | not addressed |
| Mach migrating threads | a thread that spans tasks as a chain of activations | ports | terminating a middle activation splits the thread: the server side finishes with an alert, the client side gets an error |
| erXos | a pid whose creation field is its owner's domain id, never reused while the machine runs | an import held in the router, written only by delivery, spawning and attenuating grants | one death notice to every domain, after everything the dead domain sent; each runtime fires its own links and monitors to that domain's processes |

**What erXos does** (design-domains.md). A runtime runs as an incarnation of
the machine's one node with its domain id as the node's creation, so its
pids are unique on the machine by construction and it allocates them from
its own process table with no call to anyone: the proposal's "PID ranges
... delegated" become one range per domain, the domain id, delegated once
at creation. A domain may signal another domain's process only through an
import, so a pid names and never authorises, as the proposal asks; the
import table lives in the router, a native service, not in the kernel. A
domain speaks only for its own processes, because every frame names its
sending process and the router checks that the pid carries the sender's
domain id. The proposal's batched "lifecycle events" become one death
notice per domain, ordered after the dead domain's frames; the guardian
learns of every end through the fault endpoint and tells the router first.
Stopping a domain never needs its runtime, while killing a process goes to
its runtime under a deadline, after which policy may stop the domain. The
resource manager is Erlang in the system domain, and the guardian keeps the
authority to restart the router and the system domain (design-system.md).

**What the sources contribute.** Psyche shows that the kernel need know a
process only when it crosses a domain, which erXos takes further: the
router, not the kernel, sees crossings. Resource Containers separate the
principal that pays from the domain that protects, which is erXos's split
between groups and spaces. Singularity and Mach show death without the dying
party's cooperation, each peer learning of it when it next uses the broken
channel or call; E-D3 measures how fast erXos's notices reach every linked
process. JX's never-reused ids correspond to erXos's
domain ids, and its finding that reference counts across domains miss
cycles is a reason to keep imports as records in the router rather than as
counted references (inferred; the design gives facets, not this, as its
reason for irrevocable imports). Hand's revocation by deadline, then
kill, has the shape of erXos's kill deadline.

## Kernel execution models

**Fluke** (B. Ford, M. Hibler, J. Lepreau, R. McGrath and P. Tullmann,
"Interface and Execution Models in the Fluke Kernel", OSDI 1999, 16 pages,
`b/fluke-osdi99/`, `21d22d163ce8cdec`, read in full) offers both models in
one kernel. Its API is atomic: "no thread is ever in the middle of any
system call"; a long-blocking state is itself an entry point, and the kernel
updates a thread's parameter registers in place. It names two
requirements: promptness, so that another thread can always get or set a
thread's complete state, and correctness, so that extracting, destroying,
recreating and restoring a thread is indistinguishable from leaving it
alone. Numbers (cited; 200 MHz Pentium Pro):

* of 107 calls, 8 are trivial, 68 short, 8 long and 23 multi-stage; a
  restart costs 2 to 8% of the operation;
* Table 6, latency of a 1 ms periodic high-priority kernel thread, average
  and maximum µs (the text layer drops the µ sign): process model without
  preemption 28.9 and 7,430; with one preemption point on the IPC copy path
  18.0 and 1,200; fully preemptible 5.14 and 19.6; interrupt model without
  preemption 30.4 and 7,356; with the preemption point 18.7 and 1,272
  (`lepreau.layout.txt:730-734`) *(checked)*;
* Table 5: full preemptibility costs 20% on the kernel-intensive flukeperf
  and 5% on gcc; the interrupt model runs flukeperf 6% faster than the
  process model, because a thread that restarts saves no kernel register
  state;
* Table 7, thread memory: FreeBSD 8,832 bytes and Linux 6,491 in the process
  model; Mach 4,474 in the process model and 690 in the interrupt model;
  Fluke's interrupt model 300. The paper adds that much of the reduction
  "can also be achieved in process-model kernels simply by structuring" them
  with small stacks *(checked)*.

**Mach migrating threads** (B. Ford and J. Lepreau, "Evolving Mach 3.0 to a
Migrating Thread Model", USENIX Winter 1994, pp. 97-114, `b/ford-usenix94/`,
`c5a26bb71e3264a5`, read in full) splits Mach's thread into a schedulable
thread and per-task activations; a migrating RPC takes an activation from
the server's pool and "never involves the scheduler". Terminating a middle
activation splits the thread. What broke was user-level threading inside
servers: incoming threads "are not interchangeable" and must return on the
kernel thread they came in on. Null-RPC kernel instructions fell from 1,128
to 213 and cycles from 2,318 to 648 on a 67 MHz PA-RISC (cited). erXos takes
split-on-terminate and accounting that follows the caller, and rejects
migrating foreign threads into runtime domains, whose executors cannot host
them.

**seL4**, as read for this record in the MCS paper, "is non-preemptible
(save for explicit preemption points in a few long-running operations)"
(`scheduling-context-capabilities.txt:432-433`, citing Klein et al. 2009)
and checks on entry, except on the IPC fast path, that a thread has enough
budget to complete its operation, so every queued thread can leave the
kernel (476-486) *(checked)*. That seL4 runs on one kernel stack per CPU
and restarts an operation preempted at one of those points is the design
documents' characterisation, citing Klein et al. and the seL4 manual,
neither of which was read for this record (**unverified** here).

**Fiasco** uses the process model: its thread descriptors contain "a kernel
stack, areas for saving CPU registers" (`hohmuth.txt:380-385`) *(checked)*;
the kernel is preemptible and its critical sections never sleep
(`hohmuth.txt:255-262`); a thread that wants a busy lock lends its CPU to the
holder (helping locks, `switch_exec_helping` and `Switch_lock` at `50bbe8a9`);
and `Pi_mutex` adds priority inheritance. In the measured build, the locking
group is 3,922 lines, of which `pi_mutex.cpp` is 1,336, `rcupdate.cpp` 518,
`switch_lock.cpp` 466, `cpu_call.cpp` 341 and `helping_lock.cpp` 118 ([Fiasco
sizes](#fiasco-sizes)). NOVA's authors warn that helping and donation chains
are themselves an attack surface ("a long donation or helping chain").

**Why erXos's own kernel uses one kernel stack per CPU.** The design gives
four reasons (design-kernel.md, Execution model and locking, and
Alternatives considered, The process model), each with support in the
sources:

1. a stopped thread's whole state is its record, so it can be read, copied
   or destroyed at any time, which is Fluke's promptness and correctness;
2. a kernel that is never preempted needs no helping locks and no priority
   inheritance inside itself, which Fiasco needs because it is preemptible;
3. a thread costs a record, not a stack (Fluke's Table 7), although Fluke
   notes that small stacks recover much of the difference;
4. the stack proof covers one stack per CPU instead of one per thread.

The cost is latency bounded by the longest non-preemptible stretch. The
design states that restartable calls "give the same latency with less
mechanism". Fluke measured 7.4 ms worst cases in both models without
preemption points, 1.2 to 1.3 ms with one point on the IPC copy path, and
19.6 µs only in the fully preemptible process model, which cost 5 to 20%
of throughput. erXos bounds every part of a call at 50 µs under HVF by
restarting long calls, which is the interrupt model with many preemption
points. Its latency matches a preemptible kernel's only where every part
is as short as that kernel's non-preemptible sections, and the 50 µs
budget is unmeasured; Fluke's 2 to 8% restart cost suggests what
restarting costs (inferred).

## Fiasco under HVF

A hands-on check run on 2026-10-29 from 22:05 to 23:00 PDT, recorded in
full in `~/erxos-scratch/draft/research-results/fiasco-hvf-check.md`.

* **Host.** The primary host above; Xcode 27.1 (27A9275). The host was
  shared: one-minute load averages were 12 to 65 during the measurements.
* **Tools.** QEMU 11.1.2 (Homebrew, `virt-11.1`); `aarch64-elf-gcc` 16.2.0;
  `aarch64-elf-binutils` 2.47; GNU make 4.4.1, gawk 5.4.1, bash 5.3.20,
  findutils 4.11.0, gnu-sed 4.9, coreutils 9.12, dtc 1.8.1, u-boot-tools
  2026.10; Apple clang 21.0.0 as host compiler; Ruby 4.0.7 for the harness.
* **Sources.** The L4Re snapshot 26.09.0 (published 2026-09-27; SHA-256
  `6c24687b22e1fca1`, matching the published `SHA256SUM`); Fiasco
  `50bbe8a9`; `l4re-core` `e2e2d5af`; `mk` `22cc26e5`, `bootstrap`
  `a4f4ad18`, `hello` `0513c99b`, `drivers-frst` `6459d709` and `libfdt`
  `5756062b` as GitHub archives whose hashes were recorded.
* **Method.** Every guest ran under a Ruby harness: QEMU with standard input
  closed, `-no-reboot`, no display or monitor, the serial port on a Unix
  socket, each serial line timestamped with the host's monotonic clock,
  scripted keystrokes, a hard deadline, and the guest killed with `SIGTERM`
  then `SIGKILL` on every exit path. The main HVF configuration was
  `-accel hvf -cpu host -M virt,gic-version=3 -smp 4 -m 1024`.

**Boot results.**

| Kernel | Accelerator and interrupt controller | CPUs | Result |
| --- | --- | --- | --- |
| snapshot, EL1 (`CONFIG_CPU_VIRT` off), generic device-tree platform | TCG `cortex-a57`, QEMU's GICv3 | 4 | boots to `hello`; ITS found |
| the same | HVF `-cpu host`, Apple's vGIC | 4 and 8 | boots to `hello`; no LPIs; kernel debugger on all CPUs; threads migrate across all 8 CPUs; `ex_vcpu` runs |
| the same | HVF with QEMU's GICv3 (`kernel-irqchip=off`) | 4 | boots; LPIs and ITS found |
| snapshot, EL1, Fiasco's QEMU `virt` platform | TCG and HVF | 4 | boots; under HVF its fixed ITS address is never touched because `GICD_TYPER.LPIS` is 0 |
| snapshot, EL2 (the guide's default) | TCG with `virtualization=on` | 4 | boots |
| snapshot, EL2 | HVF with nested virtualisation | 1 and 4 | the kernel initialises and the first user thread never runs |
| `50bbe8a9`, EL1, with the snapshot's user land | TCG and HVF | 4 | `bootstrap` assertion: the kernel info page layouts differ (`arch_cpuinfo[67]` in the snapshot, `[23]` on GitHub) |
| `50bbe8a9`, EL1, with a user land from GitHub heads | TCG, and HVF with Apple's vGIC | 4 | boots to `hello` |

**Findings.**

* **Timer.** Fiasco reads `CNTFRQ_EL0` as 24 MHz under HVF and 62.5 MHz under
  TCG with `cortex-a57`, and runs a 1 kHz periodic tick. Under HVF, 59
  intervals of `hello`'s one-second sleep averaged 1.000797 s by the host's
  clock.
* **Interrupts.** The timer PPI, a device SPI (PL011 receive, INTID 33) and
  SGIs all arrive through Apple's vGIC, which reports 1,024 interrupt IDs
  and no LPIs. Fiasco has no GICv2m code, so it has no MSIs under Apple's
  vGIC (inferred: PCI devices would need INTx or a GICv2m driver); no MSI
  was delivered in any configuration (**unverified**).
* **EL2 under HVF.** The only page fault is at instruction address `0x400`,
  the lower-EL synchronous vector offset with `VBAR_EL1` at 0, although
  Fiasco runs user threads with `HCR_EL2.TGE` set. The record infers that
  Hypervisor.framework's nested EL2, which is nVHE only, does not honour
  `TGE=1` with `E2H=0`; `ESR_EL1` and `ELR_EL1` were not read
  (**unverified**).
* **Snapshot and GitHub differ.** `diff -rq` lists 58 entries between the
  snapshot's Fiasco and `50bbe8a9` and 143 between the user lands; a kernel
  and its user land must come from one tree.
* **Build.** Fiasco needed no change. L4Re's user land needed one line in
  `l4/tool/Makefile` to skip `elf-patcher`, which includes `<elf.h>` and
  `<endian.h>` that macOS lacks and which nothing invokes. The kernel built
  in 23 s and the whole user land in 7 min 44 s, with no compiler warnings in
  the kernel.
* **QEMU.** QEMU 11.1.2 kept running after `SIGALRM` and stopped on
  `SIGTERM`, so `perl -e 'alarm shift; exec @ARGV'` is no deadline for a
  guest. Under HVF, `-cpu cortex-a57` aborts QEMU before the guest starts;
  HVF guests use `-cpu host`.

**The vCPU round trip.** A benchmark (`vcpu_rt`, C on L4Re's C API) resumes
a vCPU into a user task whose only code is `svc #0; b 1b`, takes the
exception upcall, steps the PC and resumes again: two kernel entries, two
exits and two address-space switches per round. The counter is
`CNTVCT_EL0` read at EL0 after an `isb` (41.67 ns per tick); each run is
10,000 warm-up rounds and 1,000,000 timed rounds, also split into 1,000
batches whose means give the percentiles; the vCPU thread was pinned to
CPU 1 of 4. The erXos probe of [research-baselines.md](research-baselines.md)
ran interleaved on the same host (`-smp 1`, interrupts off). Values in ns
per round, four runs at a one-minute load average of 12 to 13:

| Path on the M4 under HVF | Crossings | Address-space switches | Measured |
| --- | --- | --- | --- |
| erXos probe: EL0 `svc` to an EL1 handler and back (`svc_min`) | 1 | 0 | 22.0 to 22.9 |
| erXos probe: the same with a `TTBR0` switch (`svc_asid`) | 1 | 1 | 30.6 to 32.1 |
| Fiasco null system call (a thread-control IPC the kernel rejects early) | 1 | 0 | 29.3 median; 29.4 to 30.0 mean |
| vCPU round trip, user task's FPU enabled | 2 | 2 | 140.4 to 141.2 median; 142.5 to 143.7 mean; p99 161.9 to 201.4 |
| vCPU round trip, user task's FPU disabled (Fiasco's default) | 2 | 2 | 180.5 to 183.7 median |

* The round trip costs about 4.5 times the probe's crossing with an
  address-space switch, and about 79 ns more than two such crossings
  (inferred by subtraction; the probe's handler does no kernel work).
* Disabling the user task's FPU adds about 40 ns per round; the record
  guesses that writes to `CPACR_EL1` trap to the host under HVF
  (**unverified**).
* At one-minute load averages of 40 to 54, the snapshot kernel and
  `50bbe8a9` were indistinguishable (FPU enabled: run medians 139.9 to 159.0
  and 137.0 to 159.5 ns); absolute numbers rose 5 to 10% with load, as did
  the probe's.
* Under TCG the null system call took 846 ns and the round trip 11.7 µs
  (FPU enabled); TCG is not a performance reference.

L4Re's `ipcbench` and `syscallbench` (load 44) count in Hypervisor.framework's
emulated cycle counter. Every total was a multiple of 128, so the record
reads the counter as advancing 128 per 24 MHz tick, a nominal 3.072 GHz
(inferred). On that reading:

| Benchmark | Emulated cycles | ns at 3.072 GHz (inferred) |
| --- | --- | --- |
| IPC within one address space, one way | 158 | 51 |
| IPC between two address spaces, one way | 273 | 89 |
| system call, one core | 101 | 33 |
| system call, four cores in parallel | 90 to 95 | 29 to 31 |

The 33 ns system call agrees with the 29.4 to 30.0 ns measured directly for
the same operation, which supports the reading.

**Not verified by the check.** MSI delivery of any kind; interrupt latency
from a timer deadline to its handler; one-shot and tickless timers; runs
longer than 60 s; the cause of the EL2 hang and of the FPU premium; a page
fault answered by a flexpage on resume; ERTS as an L4Re program; behaviour
under `-icount`; whether a full `ham sync` builds on macOS.

**What it means for the design.** The stopgap is viable under HVF when built
for EL1, and the design builds it that way (design-kernel.md, The current
implementation). Devices under Apple's vGIC need ordinary interrupts
(virtio-mmio) until a GICv2m driver exists. Dispatch through a vCPU costs
4.5 times a crossing with an address-space switch, which supports keeping
executors as plain threads. Accounting on the stopgap runs at Fiasco's 1 ms
tick.

## Fiasco sizes

**Method.** Two Ruby scripts of the design agent,
`~/erxos-scratch/design-hier/tools/attrib.rb` and `categorize.rb`, read the
preprocessed sources of the EL1 build used above
(`~/erxos-scratch/fiasco-hvf/build/fiasco-snap-el1/auto/*.cc` and `*.h`,
snapshot 26.09.0). `attrib.rb` attributes each nonblank line to the
original source file named by the nearest preceding `#line` directive and
skips lines attributed to generated files; `categorize.rb` assigns each
original file to the first subsystem whose file-name pattern it matches.
The build's configuration: the generic device-tree platform,
`CONFIG_SCHED_FIXED_PRIO`, `CONFIG_SCHED_GRANULARITY=1000`,
`CONFIG_SCHED_DEF_TIME_SLICE=10`, `CONFIG_PRIO_INHERIT`,
`CONFIG_PERFORMANCE`, `CONFIG_NDEBUG`, `CONFIG_JDB` with logging and gzip,
`CONFIG_MP_MAX_CPUS=8`, without `CONFIG_CPU_VIRT` or the one-shot timer
*(checked)*. Measured by the design agent on 2026-10-29 and re-run for this
record on 2026-10-30 with Ruby 4.0.7, with identical results: 331 source
files, 66,837 lines.

| Subsystem | Lines | Share | Largest files |
| --- | --- | --- | --- |
| kernel debugger (JDB) and trace buffer | 18,749 | 28.1% | |
| memory: mapping database, map and unmap, spaces, page tables, kernel allocators | 11,666 | 17.5% | `mapdb.cpp` 1,378; `task.cpp` 1,193; `map_util.cpp` 872; `ptab_base.cpp` 710; `kmem_alloc.cpp` 669 |
| context switch and thread core (context, thread, FPU, vCPU) | 7,793 | 11.7% | |
| interrupts: IRQ objects, ICU, GICv2 and v3, ITS, MSI | 5,560 | 8.3% | |
| boot, CPU bring-up, platform, PSCI, device tree, ACPI, UART | 5,525 | 8.3% | |
| IPC: send, receive, gates, reply capabilities, buffers | 4,288 | 6.4% | |
| locking, cross-CPU calls, RCU, helping, priority-inheritance mutex | 3,922 | 5.9% | `pi_mutex.cpp` 1,336; `rcupdate.cpp` 518; `switch_lock.cpp` 466; `cpu_call.cpp` 341 |
| kernel objects, capabilities, factory, quotas | 3,280 | 4.9% | |
| scheduling: scheduling contexts, ready queues, timeouts, ticks | 2,575 | 3.9% | `timeout.cpp` 433; `sched_context-fixed_prio.cpp` 278; `scheduler.cpp` 181; `ready_queue_fp.cpp` 138 |
| support libraries (libk, minimal libc, libfdt) | 2,400 | 3.6% | |
| other | 1,079 | 1.6% | |
| total | 66,837 | | |

**Caveats.** The grouping is by file-name patterns, first match wins, so it
is approximate: the generic-timer driver counts as scheduling, and files no
pattern matches, such as `context-arm-64.cpp`, fall into "other". Inline
assembly counts with the C++; assembly files are not counted, and the arm64
ones whose objects the build contains hold about 780 nonblank lines (`ivt.S`
344, `tramp-mp.S` 284, `kip-time.S` 95, `crt0.S` 18, and `setjmp` and
`longjmp` 40; matched by object name, inferred). Whether Fiasco's
preprocessor emits any line twice was not checked. The figures describe one
configuration; the whole `src/kern` tree for every architecture holds about
134,000 lines (root-server evaluation).

**Against the design's estimate** (inferred). design-kernel.md estimates
erXos's kernel at about 25,000 lines of C17 "from the measured sizes of
Fiasco's corresponding subsystems less its kernel debugger, mapping
database and helping locks". Removing the debugger and trace buffer
(18,749 lines), the mapping-database family (`mapdb.cpp`,
`mapping_tree.cpp`, `kobject_mapdb.cpp`, `mapping.cpp` and the three
`map_util` files, 3,380) and the helping and priority-inheritance locks
(`switch_lock.cpp`, `helping_lock.cpp` and `pi_mutex.cpp`, 1,920) leaves
about 42,800 lines. Reaching 25,000 needs a further reduction of about 40%
that the design does not itemise.

## The three models compared

The user's other conversation proposed comparing three ways to run
lightweight processes on the same Fiasco base: **native-only**, in which
every executor is an ordinary thread scheduled one to one with no group
features (the design's configuration C0); **runtime grants**, the same
threads in groups with quotas, cooperation features and donation (C1 to
C3); and **per-process kernel dispatch**, a kernel thread per lightweight
process. The design measures the first two against each other as E-S1, the
ladder, and all three as E-S2, the dispatch models
(design-scheduler.md, Performance). This section states what the
literature predicts; every prediction is an inference from the cited
evidence, and the numbers come from other platforms unless marked M4.

| Question | Native-only (C0) | Runtime grants (C1 to C3) | Per-process kernel dispatch | Evidence |
| --- | --- | --- | --- | --- |
| a message between processes of one domain (W1) | inside ERTS; the kernel only for waking a parked executor | the same | a kernel IPC or notification per message and a kernel switch per process switch | user against kernel switch: 51 against 550 µs (Psyche, 1991), Signal-Wait 37 against 441 µs (scheduler activations), 51 against 335 cycles (vCPU paper, 2010), 172 to 221 against 465 to 812 ns (Akaros, 2014); Turner: a ring-0 round trip under 50 ns, with the cost in "the complexity of the scheduling decision", SwitchTo 179 against futex 2,905 ns; M4: a trap 22 to 31 ns, Fiasco IPC 51 and 89 ns one way (converted, inferred), an ERTS round trip 410 to 1,734 ns on the host (two runs, OTP 28.4.2) |
| spawn, exit, memory per process | ERTS's | ERTS's | a kernel object, a stack and a handle per process | Null Fork 34 against 948 µs (scheduler activations); an ERTS process is 327 words (`eff_guide_processes.md:29`, OTP 29.1.2); a kernel thread's kernel state 300 to 8,832 bytes (Fluke, Table 7); ERTS gives its scheduler threads stacks of 20 to 8,192 kilowords, 128 by default (`erl_cmd.md:1271-1273`) |
| isolation from a spinning domain (W5) | round robin within an urgency level, and cpusets | quotas cap the spinner per period | needs group caps as well, since a spinner can create threads | scheduling constraints and seL4 MCS isolate with kernel budgets; Stoess's Fig. 8 shows a kernel scheduler that ignores a guest's needs cutting throughput by 84% |
| oversubscription and lock holders (W4, W6) | stranding and lock-holder preemption | capacity advice, deferral and status words | no runtime run queues, but ETS and process locks remain user-level locks | MCS lock throughput fell to 0 and holder-aware locks kept 250 per ms (Akaros); Psyche's warning gave 2.5 times at multiprogramming level 2; activations doubled N-body speedup (1.29 to 2.45); 512 pthreads took 221 s on 32 Linux cores where 512 user threads took 72 s on 31 Akaros cores (Table 7.1) |
| priority across domains (W7) | none | donation, charge words, receive boost | the kernel sees every process's priority and can donate per call | seL4 and Credo donate per call; flattening enforces a few bands without an object per process |
| cost of the mechanism | none | +32 to 37 cycles per switch for one constraint and 0.004 to 5.3% run time (scheduling constraints, Cortex-A72); 1 to 1.5% for a polled word (Concord) | a kernel entry per block, wake and switch | as cited |

**Predictions** (inferred):

* **Per-process kernel dispatch loses on spawn and exit** by the one
  measured factor, 28 times (Null Fork, on the Firefly), and **on memory**
  by as much as the stack each thread needs exceeds an ERTS process's 327
  words (2,616 bytes on a 64-bit machine): a 16 KiB stack is about 6
  times, and ERTS's smallest scheduler stack, 20 kilowords, about 60 times;
  the kernel record adds 300 to 8,832 bytes (Fluke's range). On messaging
  and switching the sources measured kernel paths about 3 to 16 times
  slower than user-level ones. On the M4 a trap costs 22 to 31 ns and a
  Fiasco IPC 51 to 89 ns one way, small beside an ERTS round trip of 410 to
  1,734 ns on the host, so what decides is the cost Turner names, the
  scheduling decision and the wake, which no source measures on the M4;
  the record makes no numeric prediction for it. Per-process dispatch's
  one advantage, that the kernel sees every process's priority, is
  available at band granularity without it (flattening).
* **Native-only matches runtime grants** when domains do not share CPUs:
  Klues found user-level threading itself to be the dominant gain and
  composition worth only 2.3 to 10%, and the scheduling constraints cost
  under 6% in every workload measured. With the policy's capacity rule
  keeping each CPU's capacities within one CPU, the steady state is that
  case.
* **Runtime grants pay under oversubscription and contention**: up to about
  two times in the older measurements of parallel jobs sharing processors
  (scheduler activations, Psyche), and as isolation when a neighbour spins
  (quotas). Donation pays only in the cross-domain inversion of W7.
* **The decisive arms** are W4 to W7 under oversubscription; W1 to W3
  measure what the mechanism costs when it is not needed.

**Gaps in E-S2 as written.** Spawn and memory at 10^5 and 10^6 processes,
where kernel threads meet their budgets first; and an arm in which the
per-process kernel threads sit in a capped group, so that isolation is
compared like for like.

## Experiments: sources and predictions

The design's experiments, the sources that motivate each, the readers'
experiment identifiers it absorbs (from the extracts), and what the sources
predict. Predictions are inferences.

| Experiment | Motivating sources (extract ids) | What the sources predict |
| --- | --- | --- |
| **E-S1**, the ladder C0 to C3 | Stoess (A1-X1, A1-X2); scheduler activations Table V (SA2); Psyche's warning (P1); Arachne's stranding; Akaros's lock benchmark; the overheads of the scheduling constraints and seL4 MCS; Concord (C-E8); ghOSt's decision-latency ladder (C-E2); Klues on Lithe; helper B's E10 | C1 costs tens of cycles per switch; C2 pays only when groups share CPUs or a runtime oversubscribes; C3 pays for cross-domain inversion; with disjoint cpusets C0 and C3 differ by a few percent |
| **E-S2**, dispatch models | Psyche; scheduler activations Table IV; the vCPU paper; Akaros; Turner; Singularity; the Solaris white paper; Slite; Mach; Fluke Table 7 (E-SING-3) | per-process dispatch loses on spawn and exit (28 times in the one measurement) and on memory by a stack per process; on switches by about 3 to 16 times on older hardware, by an unknown factor on the M4 |
| **E-S3**, critical sections | Linux `rseq` (5 µs default, 50 µs maximum); Solaris; Psyche's 3 ms warning; Arachne's 10 ms; Caladan's few microseconds; Concord, whose preemptions miss a 5 µs quantum by a standard deviation of 0.29 µs on average and 1.8 µs at most (Table 1; C-E8); HSFQ's longest quantum (H2); Tessellation's bounded flag regions; JX's collector stalls (E-JX-3) | no source measures ERTS; Linux's default serves short sections |
| **E-S4**, wake latency | Barrelfish TN-009 (BF2); ghOSt's remote schedule (1,772 ns end to end); Shinjuku's interrupt costs (C-E10); NOVA's staggered wakeups; Syrup's late binding (C-E5); Nemesis' sends as hints (N3) | an interrupt-driven wake costs 1 to 2 µs on x86; the cost of an SGI under HVF is unknown, so the 2 to 20 µs estimate stands untested |
| **E-S5**, accounting | CPU inheritance (C1); Resource Containers (R1; a rebinding costs 1.04 µs); seL4 donation (A4-X1); Credo; Parmer (B-E8); Nemesis' crosstalk | the error is bounded by the accounting quantum: one 1 ms tick on the stopgap, the one-shot timer on erXos's kernel; a rebinding call costs a kernel entry where a charge word costs a store |
| **E-S6**, lock holders | Rhoden's lock benchmark (helper B's E5); Psyche; Williams; scheduler activations' recovery; Concord (C-E9); restartable sequences (B-E2, E-SPIN-3) | mitigation pays most under oversubscription |
| **E-S7**, quota accuracy | scheduling-constraint budgets (A3-X1); seL4's sporadic servers; Resource Containers, accurate only over tens of seconds (R2); Nemesis' jitter at 122 µs granularity | on the stopgap the error bound is one 1 ms tick per CPU per period, so the 1 ms period, or any quota near 1 ms per period, cannot be measured meaningfully there |
| **E-S8**, inversion | seL4's passive servers and ceiling protocol; CPU inheritance; Resource Containers; Nemesis' per-client bindings; temporal capabilities' cosDist (B-E3); HSFQ's unsolved inversion across classes; the user's critique, risk B | donation removes the inversion except the first period's delay; cosDist sustained about 70,000 messages per second at any Dom0 budget (reading), evidence that a request can carry its donor |
| **E-S9**, capacity | scheduler activations (SA2); OTP's warning on binding; ERTS's CPU-quota default; Solaris and Arachne on choosing the number of threads; Shenango's and Caladan's congestion signals (S1) | capacity advice recovers much of the oversubscription loss; ERTS already limits schedulers online under a detected CPU quota (`erl_cmd.md:903-905`) |
| **E-S10**, blocking refusal | scheduler activations' blocked activations; Williams' preallocated LWPs; Akaros's asynchronous system calls; Inferno's `release` and `acquire`; Singularity | no source counts blocking NIFs in OTP |
| **E-D1**, messaging cost | Barrelfish's LRPC (270 to 774 ns); Nemesis' null RPC (30 µs); Singularity's channels; JX's portal calls; Converse's queueing (9 to 15 µs); Fiasco's IPC on the M4 | four kernel calls of about 30 ns are a small part of the 3 µs budget; copies, the funnel and wakes dominate |
| **E-D2**, router scale | ghOSt's global agent (1.5 to 2.52 million decisions per second); Syrup's policy cost (under 2,000 cycles); Shenango's IOKernel | 2 million frames per second per executor leaves 500 ns per frame |
| **E-D3**, death and kill | Mach's split on terminate (E11); Fluke's promptness (E9, E10); Singularity's unwinding (E-SING-4); JX's abort flags; Hand's revocation deadline; Tessellation | death observed without the dying party's help: a broken call fails at its caller (Mach) and a peer sees the failure at its next receive (Singularity); seL4's kill timeout handler, a related action, takes 4.36 to 22.1 µs (cited) |
| **E-D4**, receivers that stop draining | none: no source read for this record studies a send pool shared by one sender's destinations | no prediction from the sources |

## Further experiments

Ideas the research suggests that the design does not list. Each runs under
HVF for numbers and under TCG for correctness only, never compared.

* **X1, pinned executors on shared CPUs.**
  * *Hypothesis.* Pinning every executor, the adapter's default, costs little
    while the policy keeps each CPU's capacities within one CPU, and much
    when cpusets overlap.
  * *Method.* E-S9's four ERTS domains on eight CPUs with overlapping
    cpusets, executors pinned and unpinned (placed only at wake), with and
    without capacity advice. The adapter pins dirty CPU schedulers by the
    same rule as normal ones, so dirty CPU scheduler `i` shares a CPU with
    normal scheduler `i` (inferred from design-runtime.md, Scheduling); one
    arm runs CPU-bound dirty NIFs.
  * *Measurement.* Throughput, p99 latency, run-queue lengths and executor
    ready time.
  * *Decision.* Whether the adapter pins by default, and whether the policy
    must keep the cpusets of pinned runtimes disjoint. OTP warns that
    binding when other processes also bind "can sometimes be severe"
    (`erl_cmd.md:1066-1073`).
* **X2, the payer fallback against a hostile client.**
  * *Hypothesis.* A client whose payer is exhausted makes a server spend,
    per period, at most the work of its outstanding calls (one per client
    thread), and at most the rest of the period on each server thread
    serving one.
  * *Method.* A native server under call donation; a client with many
    threads, a tiny quota and long requests; an honest second client; and
    an ERTS service behind a facet serving a client whose donated group is
    exhausted.
  * *Measurement.* Server time spent through fallback per period; the
    honest client's latency; fallback counts.
  * *Decision.* Keep the fallback, fail the call with a status, or send a
    timeout fault to a handler that may extend or abort, as seL4 does
    ([Hierarchy and flattening](#hierarchy-and-flattening)).
* **X3, bursts at period boundaries and stranded local quota.**
  * *Hypothesis.* A capped group can spend nearly twice its quota in one
    period's worth of time straddling a boundary; and quota drawn into the
    local slices of CPUs where the group no longer runs throttles its busy
    CPUs while the pool's quota sits elsewhere.
  * *Method.* A group capped at 30% with bursty threads on four CPUs, timed
    to period boundaries, beside a victim measuring latency; a variant whose
    threads move between CPUs.
  * *Measurement.* Usage in sliding windows of one period; the victim's
    p99; throttles while other CPUs hold unused local quota.
  * *Decision.* Periodic or sporadic replenishment; returning local quota
    when a CPU idles; the draw quantum.
* **X4, ready workers beside idle CPUs.**
  * *Hypothesis.* With no load balancer, a worker preempted on a busy CPU can
    stay ready while another CPU it may use is idle.
  * *Method.* Native programs with CPU-bound workers that urgent wakeups
    preempt.
  * *Measurement.* Time each worker spends ready while an allowed CPU idles;
    throughput against a variant in which an idle CPU pulls a ready worker.
  * *Decision.* Whether idle CPUs pull ready workers; executors keep relying
    on ERTS's own stealing. Turner's slides leave balancing "to the
    load-balancer" (`lpc2013-user-threading.txt:317`), and in `sched_ext` a
    CPU whose local queue is empty takes work from the global queue before
    it idles (`sched-ext.txt:226-233`).
* **X5, notice latency for a busy domain.**
  * *Hypothesis.* An inbox bit set for a domain whose executors are all
    running is taken within one reduction slice in the common case, with a
    tail set by long BIFs, NIFs and collections.
  * *Method.* A domain with every executor busy receives frames; the router
    timestamps each signal and the adapter each drain.
  * *Measurement.* The signal-to-drain distribution, by what the executor
    was running.
  * *Decision.* Whether an urgent frame needs a yield request posted to a
    running executor of the receiving group. Sources: Barrelfish TN-009,
    HSFQ's delay bound, Caladan's 2X rule.
* **X6, lock holders preempted by urgent wakeups.**
  * *Hypothesis.* Router and driver wakeups preempt executors that hold ERTS
    locks often enough to matter under message load, because deferral does
    not apply to urgency preemption.
  * *Method.* W2 and W4 with the router sharing CPUs with executors.
  * *Measurement.* Urgency preemptions per second that hit an executor with
    `defer` raised; the other executors' spin and futex time.
  * *Decision.* Whether a short grace (Linux's 5 µs, for example) also covers
    urgency preemption below some level, or the router gets CPUs of its own.
* **X7, thread progress under oversubscription.**
  * *Hypothesis.* A preempted executor delays ERTS's thread progress, and
    with it deferred deallocation and code loading, for its whole runtime,
    because a running but preempted managed thread has not confirmed.
  * *Method.* W4 with code loading and allocation-heavy work.
  * *Measurement.* Intervals between thread-progress values; memory held
    for deferred deallocation; code-loading latency; with and without
    capacity advice and status words.
  * *Decision.* Whether capacity advice suffices or a group needs
    co-scheduling for runtime-wide barriers, which the design excludes on
    SMT grounds only. Sources: Barrelfish's dispatcher groups for
    stop-the-world collection (HotPar 2010) and phase-locked gang scheduling
    (Peter's thesis).
* **X8, timer reprogramming under HVF.**
  * *Hypothesis.* Writing `CNTV_CVAL_EL0` and `CNTV_CTL_EL0` is cheap under
    HVF, so a one-shot timer reprogrammed at most decisions is affordable.
  * *Method.* The erXos probe with a loop of compare-register writes.
  * *Measurement.* Nanoseconds per write and per write-and-read pair.
  * *Decision.* Whether erXos's kernel skips reprogramming when the earliest
    deadline is unchanged. seL4's schedule path costs 38 to 45% more with
    MCS, which its authors attribute to reading and reprogramming the timer
    and to sporadic replenishment, and a switch without reprogramming was
    "almost 70% faster" with temporal capabilities.
* **X9, cancelling nested calls.**
  * *Hypothesis.* When a caller's deadline passes while its server is itself
    in a call, the inner server keeps charging the abandoned caller's payer
    until it replies.
  * *Method.* A chain of three native servers; expire the outer deadline;
    kill each party in turn.
  * *Measurement.* Time charged to the original payer after its deadline;
    leaked references; replies failing with `ERX_ENOCALLER`.
  * *Decision.* Whether a cancellation propagates down the chain, as Mach's
    alerts do, or inner calls keep the payer until they return.

## The user's critique, claim by claim

The user's critique of two-level scheduling, which the design adopted
(`~/erxos-scratch/draft/inputs/user-two-level-scheduling.md`, pasted on
2026-10-29), checked against the sources read for this record. Its
proposals for erXos are design input and are not listed. Verdicts:
*supported*, *partly supported* (part of the claim is confirmed and part is
not covered), *unverifiable* (no source read covers it), *contradicted*
(none was).

| # | Claim | Verdict | Evidence |
| --- | --- | --- | --- |
| U1 | Scheduler activations were abandoned largely because their complexity and overhead outweighed their benefits once 1:1 kernel threads became efficient. | partly supported | complexity and poor multiprocessor scaling (NetBSD), a 1:1 library "simpler" and "sufficient" (Solaris), the O(1) scheduler making the motivation moot (NPTL); but FreeBSD's stated reason was development cost, and Wemm judged KSE "almost certainly more efficient at runtime"; overhead appears only as Williams' common-case spinlock cost and the original prototype's 2.4 ms upcall path |
| U2 | Modern Erlang/OTP already uses a form of M:N scheduling. | supported | ERTS runs many processes over scheduler threads whose number defaults to the logical processors (`erl_cmd.md:897-905`) *(checked)* |
| U3 | The kernel allocates virtual processors, the application schedules its threads on them, and the kernel upcalls on block, wake and preemption. | supported | Tables II and III of the TOCS paper |
| U4 | NetBSD introduced scheduler activations in NetBSD 2.0 (2004). | unverifiable | no source read gives the release; Williams (2002) expected integration "after the release of NetBSD 1.6" (`williams.raw.txt:757-761`), and the 5.0 changes add compatibility for NetBSD 2, 3 and 4 thread libraries *(checked)* |
| U5 | NetBSD replaced them with a 1:1 implementation in NetBSD 5.0 (April 2009). | partly supported | 1:1 in 5.0 is confirmed by the announcement and by Rasiukevicius (article dated 4 May 2009); the month is not given in the copies read |
| U6 | Rasiukevicius: the implementation was complicated, scaled poorly on multiprocessors and lacked real-time support. | supported | `netbsd_5_scheduling_apis.raw.txt:12-13` *(checked)* |
| U7 | The replacement coincided with substantial scheduler and synchronisation improvements, so it was not an isolated comparison. | supported | the 5.0 announcement credits the 1:1 library with "new kernel synchronization primitives, kernel preemption, a rewritten scheduler implementation"; the newlock2 merge did both (`changes-5.0.html:789`) *(checked)* |
| U8 | FreeBSD's KSE was closely related, and its M:N `libkse` competed with the 1:1 `libthr`. | supported | `kse(2)`; Wemm's 2003 thread "libthr and 1:1 threading" *(checked)* |
| U9 | FreeBSD 7.0 (February 2008) made `libthr` the default. | supported | the 7.0 announcement of 27 February 2008: "The 1:1 libthr threading model is now the default" *(checked)* |
| U10 | FreeBSD 8.0 (2009) removed KSE. | partly supported | kernel KSE was removed on 2008-03-12 on the development branch (`UPDATING` entry 20080312), and a later commit restores the ability "to debug kse coredumps in 8.0" *(checked)*; 8.0's release year is not in the sources read |
| U11 | FreeBSD's `libthr(3)` described significant performance advantages over `libkse` for system-scope thread semantics. | unverifiable | `libthr(3)` was not read; the 7.0 announcement lists the `libthr` default among the changes behind its performance gains |
| U12 | Kernel developers pointed to KSE's complicated scheduler paths and the difficulty of optimising them. | partly supported | Roberson: the M:N approach "was never developed to its full potential"; Wemm: 1:1 is easier to write, maintain and debug; no source read speaks of scheduler paths |
| U13 | In Williams' NetBSD implementation, an upcall could re-enter the user scheduler inside a critical section, and special machinery recovered interrupted critical sections. | supported | `williams.raw.txt:600-647` *(checked)* |
| U14 | When an activation blocked, NetBSD had to arrange another activation to notify user space. | supported | the "blocked" upcall delivered on a new LWP (`williams.raw.txt:520-560`) *(checked)* |
| U15 | NetBSD needed preallocated LWPs because allocating a replacement while blocking could recurse. | supported | "a spare LWP is pre-allocated and cached" so that "no double-sleep recursion occurs" (`williams.raw.txt:562-566`) *(checked)* |
| U16 | POSIX signal delivery required another layer of cooperation between kernel and library. | supported | `williams.raw.txt:352-367, 484-487` *(checked)* |
| U17 | The big architectural problem was two schedulers jointly owning the state of one execution context. | judgement, consistent | Solaris: a user-level scheduler that "works well in tandem with the kernel's scheduler is a significant challenge"; NPTL: two schedulers that do not collaborate; `kse(2)`'s atomicity requirement |
| U18 | BEAM already runs many processes over a few scheduler threads, typically related to the CPU count, on Linux, FreeBSD and NetBSD. | supported | `erl_cmd.md:897-905` *(checked)*; the documentation does not name operating systems |
| U19 | A timer interrupt during garbage collection is harmless if the kernel resumes the same thread where it stopped. | judgement, consistent | the vCPU paper, Barrelfish and Akaros resume in place; it holds for correctness, while lock holders and thread progress still suffer ([Lock-holder preemption](#lock-holder-preemption), X7) |
| U20 | Erlang has I/O polling and dirty schedulers for native operations that cannot run on ordinary schedulers. | supported | `+SDcpu` and `+SDio` in `erl_cmd.md` *(checked)* |
| U21 | Scheduler activations addressed blocking by supplying replacement activations. | supported | the "activation has blocked" upcall and the I/O example (`sched_act.squeezed.txt:455-502`) |
| U22 | CPU inheritance scheduling and seL4's scheduling contexts explore donation of CPU budget or priority along IPC dependencies. | supported | Ford and Susarla; Lyons et al. |
| U23 | Advisory hints cannot enforce strict per-process deadlines across untrusted domains. | judgement, consistent | scheduler activations guard against dishonest hints with feedback; Stoess admits no control over "priority inversion and time isolation" |
| U24 | Erlang's documentation warns of potentially severe penalties when several VMs bind scheduler threads to competing logical processors. | supported | "This performance penalty can sometimes be severe" (`erl_cmd.md:1066-1073`) *(checked)* |
| U25 | The Akaros work revisits scheduler activations, distinguishes allocating kernel threads from allocating cores, and explores asynchronous system calls and explicit core grants. | supported | Rhoden, `EECS-2014-223.txt:1710-1714, 1840-1884`; the critique's link names Rhoden's title |
| U26 | Stoess implements hierarchical user-level scheduling on an L4 kernel with 0 to 10% overhead against an in-kernel scheduler for the applications evaluated. | supported | `stoess07.txt:36, 139` *(checked)*; the same paper reports 1.4 to 2.1 µs per level and 7.8% per 2 ms tick under heavy I/O |
| U27 | Barrelfish's dispatchers use upcalls and distinguish execution inside the scheduler's critical section, at the price of additional machinery. | supported | the disabled word, the critical PC range and three save areas ([Barrelfish](#barrelfish-architecture-and-dispatchers-2013)) |
| U28 | The lesson is that joint management of arbitrary POSIX threads by kernel and library cost more machinery than its benefit justified. | judgement, consistent | the common factor inferred under [Negative evidence](#negative-evidence) |

Of 24 factual claims, 18 are supported, 4 partly supported and 2
unverifiable; the 4 judgements are consistent with the sources.

## Corrections to the proposal's references

* **Akaros.** The link, UCB/EECS-2014-223, is B. Rhoden, "Operating System
  Support for Parallel Processes" (18 December 2014), and its label "Akaros
  many-core process/core grants (2014)" fits it. The readers' brief
  attributed it to Klues, whose thesis is UCB/EECS-2015-188 (13 August
  2015) *(checked)*; both were read. The local directory `akaros-klues/`
  holds Rhoden's thesis.
* **Stoess.** The paper's title is "Towards Effective User-Controlled
  Scheduling for Microkernel-Based Systems" (ACM SIGOPS OSR 41(4), July
  2007, pp. 59-68); "User-Controlled L4 Scheduling" is the file name.
* **Nemesis.** The link is an index of the Cambridge group's papers, not a
  paper. The record uses the JSAC article of 1996 (in the authors' 1997
  render), Roscoe's TR-376 (1995) and Hand's OSDI paper (1999).
* **Scheduler activations.** The linked page carries the SOSP 1991 paper
  and the TOCS 1992 article; the TOCS version was read.
* **Converse.** The linked PPL page gives IPPS 1996 with five authors; the
  PDF behind it lists four and cites 1995 venues as "to appear", so it is
  probably a preprint.
* **L4Re/Fiasco source.** The link is `github.com/L4Re/fiasco`; the work
  used `github.com/kernkonzept/fiasco` at `50bbe8a9` and the 26.09.0
  snapshot, which differ from each other. Whether the two URLs serve one
  history was not checked.
* **L4Re architecture.** The concept pages on scheduling, IPC and memory
  under the linked introduction were "Under Construction" (last updated
  2026-10-26), so the reference carries no scheduling content.
* **L4Re Scheduler and vCPU APIs.** The Doxygen pages were not fetched;
  the headers they are generated from were read.
* **Scheduling constraints.** IEEE's page returned nothing; the open
  camera-ready from TU Dresden was read. The research implementation
  (`4e9a1a9b`) is a prototype with panics reachable from requests.
* **`sched_ext`.** The link points to the "latest" kernel documentation,
  which changes; the version read was 7.3.0.
* **Inferno.** The IEEE page is paywalled; Vita Nuova's revised reprint was
  read and not compared with the original.
* **Syrup.** The page range 605-620 comes from dblp and is unverified.

## Points where the sources bear on the design

Points of tension between the sources and the design documents as they
stood when this record was compiled; each names the passage concerned.

* **The payer fallback** (design-scheduler.md, Call donation, and Payer and
  urgency resolution). A server whose caller's payer runs out continues on
  its own grant, and so does an executor whose charge word names an
  exhausted group. Lyons et al. criticise exactly this behaviour of L4
  timeslice donation, and offer a timeout fault to a handler instead;
  temporal capabilities carry finite slices with each request. The
  fallback keeps servers from stalling, at the cost of letting a client
  consume the server's grant within a bound (X2).
* **The 50 µs grace** (design-scheduler.md, Deferred preemption). It is Linux's
  maximum; Linux's default and minimum is 5 µs, and its documentation
  requires evidence to raise the default. No source measures ERTS's lock
  hold times (E-S3), and urgency preemption is never deferred (X6).
* **No load balancer** (design-scheduler.md, Requirements, and Placement and
  affinity). Executors are balanced by ERTS's stealing, but native workers
  are placed only at wake; Turner left balancing to the kernel's balancer,
  and in `sched_ext` an idle CPU pulls from a global queue (X4).
* **Gang scheduling excluded on SMT grounds alone** (design-scheduler.md,
  Requirements). Barrelfish co-schedules a runtime's dispatchers for
  stop-the-world collection, and ERTS's thread progress waits for every
  running managed thread (X7).
* **Pinning by default** (design-runtime.md, Scheduling). OTP warns that
  binding when other processes bind can carry a "sometimes severe" penalty;
  the design relies on the capacity rule to keep pinned executors apart
  (X1).
* **Replenishment at period boundaries** (design-scheduler.md, Charging and
  quota). seL4 uses sporadic servers; a budget refilled per period allows up
  to twice the quota in a window that straddles a boundary (inferred, X3).
* **E-S7's 1 ms arms on the stopgap** (design-scheduler.md, Performance). With
  accounting at a 1 ms tick, a 1 ms period or a quota near 1 ms per period
  is below the stopgap's resolution (inferred).
* **The kernel's size estimate** (design-kernel.md, Requirements). The
  measured sizes less the debugger, the mapping database and the helping
  locks leave about 42,800 lines, not about 25,000
  ([Fiasco sizes](#fiasco-sizes)).
* **seL4 as precedent for the event model** (design-kernel.md, Context, and
  Execution model and locking). The MCS paper confirms that seL4's kernel
  is non-preemptible with preemption points in a few long operations; no
  source read for this record establishes its single kernel stack or that
  its preempted operations restart.
* **Equal latency from restartable calls** (design-kernel.md, Alternatives
  considered, The process model). The design says restartable calls "give
  the same latency with less mechanism". In Fluke only the fully
  preemptible process model reached a 19.6 µs worst case, against 1.2 ms
  or more with a preemption point on one path, so the claim holds only as
  far as every part of every call is as short as a preemptible kernel's
  non-preemptible sections; the 50 µs part bound is a budget, not a
  measurement ([Kernel execution models](#kernel-execution-models)).
* **History in the scheduler's Context section** (design-scheduler.md).
  "NetBSD shipped them in 2.0" is unverified and "KSE was removed in 8.0" is
  inferred (U4, U10).
* **Fiasco's IPC in nanoseconds** (design-kernel.md, Performance;
  design-scheduler.md, Alternatives considered). The 51 and 89 ns figures
  rest on an inferred conversion of an emulated cycle counter. The cost
  model of design-scheduler.md says so; design-kernel.md's Performance
  table and the "measured cost" of design-scheduler.md's case against a
  kernel thread per lightweight process do not.
* **The vCPU among upcall interfaces** (design-scheduler.md, Alternatives
  considered). In Fiasco `50bbe8a9` a vCPU's preemption is transparent and
  only enabled events are upcalled; the rejection rests on cost and on
  needing no event upcalls, which the measurements support.
* **Akaros's preemption notices** (design-scheduler.md, Alternatives
  considered, Core allocation). Klues and Rhoden disagree on whether Akaros
  notifies before it preempts.

## Unverified items

* The venue and usual title of the vCPU paper; Syrup's page range; the
  default of ghOSt's `runnable_timeout`; the proceedings pages of CPU
  inheritance scheduling; whether the Converse PDF differs from the IPPS
  version; whether the Inferno reprint differs from the original.
* The release year of NetBSD 2.0 and its shipping of scheduler activations;
  the month of NetBSD 5.0; the release year of FreeBSD 8.0; the content of
  `libthr(3)`; a primary statement of why Windows UMS was removed.
* Helper A's readings of the scheduling-constraints code (untested), in
  particular the inverted bandwidth timeout.
* Helper B's readings of Barrelfish's kernel (untested).
* Every value marked *(reading)*.
* In the Fiasco check: MSI delivery, interrupt latency, the cause of the EL2
  hang and of the FPU premium, and the unit of the emulated cycle counter.
* Whether `github.com/L4Re/fiasco` and `github.com/kernkonzept/fiasco` share
  history; Linux's CFS bandwidth control as a precedent for erXos's pool and
  local slices (not read).
* seL4's single kernel stack, and that its preempted operations restart
  (the MCS paper states only that the kernel is non-preemptible with
  preemption points).
* Whether another thread can shorten a running ERTS process's reduction
  budget, which a polled yield request would need (helper A).

## Local copies

| Group | Directory | Contents |
| --- | --- | --- |
| helper B and the third reader | `~/erxos-scratch/papers/a/` | Psyche, scheduler activations, Barrelfish (with the library source at `06a9f547`), Lithe, Converse, CPU inheritance, Nemesis, Akaros, Tessellation, HSFQ, Resource Containers, Arachne, Shenango, Caladan, and the negative evidence; SHA-256 in `papers/a-manifest.sha256` |
| helper A and its forks | `~/erxos-scratch/papers/b/` | the L4, Fiasco and seL4 papers, the scheduling-constraints repository, Composite (with source at `d3b9d9f2`), Fluke, Mach, ghOSt (with `ghost-userspace` at `9ca0a1fb`), Syrup, `sched_ext` (with Linux v7.3 source), Concord, Shinjuku, JX, SPIN, Singularity, Inferno (with source at `36616fe5`); SHA-256 in `report-helperA.txt`, section 6 |
| figure renders | `~/erxos-scratch/papers/b-render/`, `papers/b/_render/` | page images of graphs and tables |
| L4Re | `~/erxos-scratch/borrow/rootserver/l4/` | the Fiasco and `l4re-core` clones and the saved L4Re pages |
| the Fiasco check | `~/erxos-scratch/fiasco-hvf/` | sources, builds, harness, logs and every guest's serial log |
| extracts and notes | `~/erxos-scratch/design-hier/` | the three extracts, the design agent's notes and the size tools |
