# Research record: language-based and runtime-centred operating systems

A point-in-time survey of operating systems built around a language runtime or
on language-based isolation, and of kernel mechanisms that bear on running ERTS
in a kernel at EL1 with untrusted Erlang code in EL0 protection domains: what
each system is, the mechanisms that matter here, and its measured costs, each
with the page or section of its primary source. Systems that host BEAM itself
are in [research-erts-host.md](research-erts-host.md#prior-art). Findings here
are never edited in place; a re-check gets a new record.

**Date:** 2026-10-29.
**Host:** Apple M4 Max, macOS 27.0.1 (26A434).
**Sources read** (read only; no script, makefile or binary from them was run):
those under [Sources](#sources), accessed 2026-10-29; the re-checks used
`pdftotext` (poppler 26.10.0), curl 8.7.1 and ugrep 7.8.4.

## Method

* The record condenses a survey of these sources made for erXos on 2026-10-29;
  each was read in full text unless its entry names the copy read. "p." is the
  printed page, "PDF p." the page index of a copy without printed numbers, and
  "section" the source's own numbering.
* Quotations are verbatim, in ASCII punctuation; the rest is paraphrase.
  "(inferred)" marks an inference from the cited evidence; **unverified** marks
  a claim no source confirmed; secondary sources are marked where used.
* Bracketed keys refer to [Sources](#sources). These items were re-checked
  against the primary source for this record, and each agreed with the survey:

| Source | Re-checked |
| --- | --- |
| [S1] | "over 90%" and "48%" (p. 4); 394 cycles (p. 6); GC pause under 100 µs (p. 7); 6.3%, 18.9%, 37.7% and "under 5%" (pp. 9-10) |
| [M1] | all eight rows of Table 2 (p. 9) |
| [C1] | 115 µs and 600 µs (p. 89); "factor of 2 to 3" (p. 102) |
| [B1] | the figures cited from pp. 4, 5, 10 and 17 |
| [K1] | "no more than 11% slower" (abstract); 37 cycles and "below 7%" (PDF p. 8) |
| [G1], [G2] | the quotations from pp. 40, 42, 43 and 44 (the p. 38 passage is garbled in the scan and was not located) and from page 1615 |
| [O1] | the BeamAsm and Secure Coding quotations and both page titles |
| [W1] | the abstract quotation |

## Singularity

Microsoft Research's operating system in which each program is a
software-isolated process (SIP): sealed, type-safe code with its own runtime
and collector that talks to others only over contract-checked channels, whose
message data lives in an exchange heap with one owner per block [S1].

* **Unsafe code (pp. 4, 11).** "over 90% of the Singularity kernel is written
  in Sing#"; the collector "accounts for 48% of the unsafe code", and bugs in
  it "could undermine Singularity's security".
* **ABI (p. 5).** "By default, a SIP can do nothing more than manipulate its
  own state, and stop and start child SIPs." Handle-table slots "are reclaimed
  only when a SIP terminates"; since no call alters another process, each
  collector "executes independently".
* **Memory (p. 6).** "No SIP can have a pointer to another SIP's objects", so
  each SIP "can be garbage collected and terminated without the cooperation of
  other SIPs"; dead SIPs' exchange-heap blocks are freed by reference counting.
* **Threads (pp. 6-7).** A switch from one SIP to another takes "as few as 394
  cycles"; collector pauses stay under "100 microseconds for typical stacks"; a
  killed SIP's threads are "immediately stopped with a kernel exception, which
  skips over and deallocates the process's stack frames".
* **The unsafe code tax (pp. 9-10).** On WebFiles, paging costs 6.3%, a
  separate domain 18.9%, ring 3 33% and a ring-3 domain per SIP 37.7%, while
  "the runtime overhead for safe code is under 5%"; on x86's untagged TLB "a
  process context switch requires flushing the TLB" (p. 9).

[S2] measures optional hardware domains around SIPs, from SIP-Phys (ring 0,
paging off) to HIP-R3-S (each process in its own ring-3 domain), copying
messages across domains, on a 1.8 GHz Athlon 64 3000+ (p. 7):

* "hardware-based isolation incurs non-trivial performance costs (up to 25-33%)
  ... Software isolation has less than 5% overhead on these benchmarks", yet
  "remains valuable as a defense-in-depth" (p. 1).
* Ring 3 makes an ABI call 80 -> 304 cycles (3.8x) and process creation
  520,473 -> 830,999 (+60%) (p. 7); per-process domains make communication
  "3.9 - 9.6 times as expensive" (p. 5); safety checks cost 4.5-4.7% (p. 9).

| Cycles (Table 1, p. 8) | ABI call | Thread yield | 1-byte round trip | Process creation |
| --- | --- | --- | --- | --- |
| Singularity SIP-Phys | 80 | 365 | 1,041 | 388,162 |
| Singularity HIP-R3 | 304 | 638 | 2,580 | 830,999 |
| FreeBSD | 878 | 911 | 13,304 | 1,032,254 |
| Linux | 437 | 906 | 5,797 | 719,447 |
| Windows XP | 627 | 753 | 6,344 | 5,375,735 |

Sealed processes [S3] have fixed code, isolated state, explicit communication
and a closed API. "A process cannot dynamically load code and should not
generate code into its address space" (p. 3); "Multiplexing server processes
among multiple clients also makes resource accounting more difficult" (p. 7).
Process creation costs 352,873 cycles, cheap "because SIPs do not need MMU page
tables", and sealed code allows tree shaking, which cut code size by 46-77%
(Table 8, p. 11).

Channels [S4] are "the unique failure points" between processes (p. 5); a
"background clean-up thread" reclaims blocks whose owner has died (p. 9); a
send and receive costs a "constant around 1200 cycles" up to 64 KB (p. 11).

## SPIN

An extensible kernel: Modula-3 extensions are linked into the kernel at run
time, protection domains are linker namespaces, capabilities are typed
pointers, and extensions run when events are dispatched to them [P1].

* Safety rests on "interfaces, type safety, and automatic storage management"
  (PDF p. 3); a handler that overruns its "time quantum" can be aborted
  (PDF p. 6); "The core services are trusted" (PDF p. 9).
* A protected in-kernel call costs 0.13 µs, a system call 4 µs and a
  cross-address-space call 89 µs on a 133 MHz Alpha (Table 2, PDF p. 10).
* The paper treats neither per-extension accounting nor cleanup after an
  extension fails mid-update (inferred); later papers say "a crashing extension
  left the system in an inconsistent state" ([R1] p. 23; similarly [S2] p. 6).

## Inferno and Dis

Bell Labs' system in which Limbo programs run on the Dis virtual machine,
resources are files in per-process namespaces imported over the Styx protocol,
and the system runs native or hosted [I1].

* Limbo "programs run safely on a machine without memory-protection hardware",
  since a module's type-consistency "is checked when it is loaded" [I1].
* System objects are "freed as soon as they become unused", so a dead task's
  window disappears with its last reference; the kernel "contains the
  interpreter and on-the-fly compiler as well as memory management, scheduling,
  device drivers, protocol stacks" [I1].
* Authority follows the namespace; the paper claims "resource control" but
  describes no per-process memory or CPU limit (inferred) [I1].
* Dis collects "most garbage ... by simple reference counting, while a
  real-time coloring collector gathers cyclic data", and its JIT output "runs
  only 30-50% slower than native C" [I2].

## Genera

Symbolics' Lisp machine environment: all processes share one virtual memory of
typed, self-describing objects with no protected kernel, and databases the
compiler keeps (callers, source locations, argument lists, warnings) drive the
editor, debugger and configuration manager [G1].

* "Genera can run any number of processes at once, all sharing the same virtual
  memory. This shared memory is treated as a set of objects, not as raw bits or
  bytes" (p. 38). Genera "places no barriers between the system and the user;
  it has no protected core or kernel"; reliability comes from typed objects,
  hardware checks ("Runtime array-bounds checking prevents wild stores") and
  automatic storage reclamation (p. 40).
* Genera runs "multiple independent processes in a single address space with a
  simple priority scheduler", and "The Inspector lets users see or manipulate
  any aspect of the current state of a complex data object" (p. 42).
* **Hazards (p. 43).** "Open systems have no 'keep out' signs ... without a
  system/user distinction to warn them off, users often choose to solve a
  problem using primitives instead of facilities more appropriate to their
  problem." Layer boundaries "are mostly invisible, with no formal definition."
* **Tooling (sidebar, p. 44).** The debugger uses source locations for
  "single-key commands that invoke the editor on the function for the current
  stack frame"; the editor compiles "only the definitions that have changed";
  configuration supports "incremental patching".
* **Presentations.** Output to a dynamic window creates presentations kept in
  the window's history, which record "The underlying object, which is the
  object that was displayed" and "The presentation type, which tells how the
  object is to be classified or interpreted" (page 1615) [G2], so what a user
  sees stays a typed, live object.

## Ling (Erlang on Xen)

LING is a reimplementation of the BEAM written from scratch, not a fork of
ERTS; it boots as a Xen guest with no operating system beneath it and runs its
own bytecode derived from BEAM code [L1].

* It is "the functional equivalent of the standard Erlang VM (BEAM)", in which
  "Erlang processes become OS processes"; `.beam` files need "a (complex)
  transformation step during code loading", and the team discouraged run-time
  compilation [L1]. Kharchenko, quoted secondhand: "Hypervisor is the only
  'hardware' scheduler, Erlang processes are green threads" [Y1].
* Boot-time claims disagree: under 100 ms to application code
  (erlangonxen.org), "30ms" per domain (CIF16 slides), and "sub 250ms" with
  4 MB images from a third party [Y1]. LING is "fully functional" at 20 MB and
  "unable to boot" at 12 MB [L1].
* "The Erlang process that failed to allocate memory goes away, but the whole
  system ... continues unscathed. Unfortunately, the BEAM VM does not seem to
  take full advantage of this. The BEAM emulator is prone to crash when the
  memory is tight." LING keeps its C minimal and handles exhaustion with
  `setjmp`/`longjmp`; NIFs trade this robustness away [L1].
* Why the project ended is **unverified**: no statement was found. (inferred)
  Commercial backing ended, since the last commit falls within Kharchenko's
  role at Cloudozer, September 2012 to March 2016 [L1].

## Safe Erlang

A proposal for mobile code in Erlang: subnodes (nodes inside one runtime, each
with its own registered names, module aliases, side-effect permissions and
utilisation limits), capabilities that replace pids, ports and node names, and
remote module loading [E1].

* **Section 2.** Pids are "both forgeable and too powerful"
  (`list_to_pid([0,23,0])`, `processes()`, `exit(FakePid,kill)`); "There is no
  mechanism ... to limit the usage of a pid (to just sending messages, for
  example)", nor to limit a process's resources "apart from imposing
  restrictions on the entire system".
* **Section 3.1.** A capability is `<Type,NodeId,Value,Rights,Private>` with
  rights such as `[exit,link,register,restrict,send]`, protected by a keyed
  hash or as a sparse "password", and capabilities "are invalidated when their
  associated resource is destroyed".
* **Sections 3.2 and 4.** The alias table is "consulted to map the module name
  on all external function calls, applys, and spawns"; "Limits could be imposed
  on some of cpu usage, memory usage, max no reductions", with no enforcement
  results. The prototype inserted "glue functions" at compile time; moving the
  mechanism into the runtime would ensure it "cannot be bypassed".

## KaffeOS

A Java virtual machine with processes: each has its own heap and collector
beside a kernel heap and optional shared heaps; write barriers forbid pointers
that would block reclaiming a heap; memory limits are hierarchical, hard or
soft. It is "no more than 11% slower" than its base JVM (abstract) [K1].

* **Kernel mode without privilege (PDF p. 3).** The modes mark "different
  environments with respect to termination and resource consumption":
  "Processes running in kernel mode cannot be terminated at an arbitrary time";
  "Termination requests are deferred". Exceptions "interact poorly with code in
  critical sections, which leaves shared data structures open to corruption".
* **Accounting and sharing.** "memory cannot be revoked by unmapping pages: it
  must be garbage-collected" (PDF p. 3); accounting covers "all allocations
  done in the VM on behalf of a given process" (PDF p. 4); a shared heap is
  frozen once populated, and "All sharers are charged in full" (PDF p. 5);
  strings are interned per process, because a global table would let one
  process exhaust kernel memory (PDF p. 7).
* **Costs and isolation (PDF pp. 8-10).** The write barrier takes 37 cycles, or
  11 with a heap pointer per object, and overhead stays "consistently below
  7%". A memory-hogging servlet killed only its own process, while one shared
  IBM JVM "runs out of memory in seemingly random places".

## JX

A Java operating system: a small C microkernel hosts Java domains, each with
its own heap, collector and threads, that call each other through portals (RPC
with deep-copied parameters); all code passes a verifier and translator [J1].

* "DomainZero ... is the only domain that can not be terminated", and "A thread
  does not migrate between domains" (PDF p. 3). A null portal round trip costs
  650 cycles, with a "per-call quota for parameter data" (PDF p. 4).
* The verifier "verifies an upper limit for the execution times of the
  interrupt handlers and the scheduler methods"; busmaster DMA drivers "must be
  trusted" (PDF p. 7). A domain's `preempted()` callback runs under a verified
  time bound, which JX compares with scheduler activations (PDF pp. 7-8).

## House

An operating system in Haskell on a modified GHC runtime, whose H monad of
about twenty operations exposes page maps, user mode and device I/O [H1]. The
interface is "memory-safe in almost all circumstances; the only possible safety
violations are ones that occur via abuse of a device DMA controller"
(PDF p. 2). Interrupts wait for GHC safe points while a C handler "just sets a
flag" (PDF p. 7); whether network cards "can be adequately serviced in a
Haskell runtime environment" under garbage collection is left open (PDF p. 12).

## seL4 MCS

seL4's mixed-criticality scheduling: a scheduling context, a budget per period
replenished as a sporadic server, is a capability; a client can donate it to a
passive server over IPC; an exhausted budget raises a timeout exception to a
handler [M1].

* "An scCap represents the privilege to access the processor, it is a
  capability to time" (p. 4). The handler may grant an emergency budget, change
  criticality, kill or suspend the thread, or abandon "the request and roll[]
  the server back" (p. 5).
* With donation "time consumed by the server is billed to the client requesting
  the work", and timeout exceptions spare a client from trusting "all the
  server's other clients" (p. 6). A user-level EDF scheduler beat LITMUS^RT's
  in-kernel EDF; MCS added about 2,000 lines (14%) to the kernel (p. 13).

| Cycles, base -> MCS (Table 2, p. 9) | ARM | x64 |
| --- | --- | --- |
| IPC call | 288 -> 350 (+21%) | 448 -> 455 (+1%) |
| replyRecv | 313 -> 339 (+8%) | 431 -> 450 (+4%) |
| IRQ latency | 1,604 -> 1,813 (+13%) | 1,144 -> 1,245 (+8%) |
| schedule | 1,910 -> 2,778 (+45%) | 1,512 -> 2,100 (+38%) |

## Zircon

The kernel of Fuchsia: objects are reached through handles with rights, jobs
form a tree that carries policy, ports aggregate signals, and exceptions arrive
as channel messages; the documentation is unversioned [Z1].

* A call checks that the handle is in the caller's table, of the right type and
  with the rights; rights only shrink; object ids "are never reused"; handles
  written to a channel "are removed from the sending Process".
* Jobs "track and limit basic resource (e.g., memory, CPU) consumption", but
  `zx_job_set_policy` documents only handle-misuse, object-creation, W^X,
  VMO-executable and timer-slack policies (allow, deny, exception, kill); the
  pages read show no memory or CPU quota.
* A critical process's death kills its job; `zx_task_kill` kills a tree;
  exception handlers are tried in a fixed order (debugger, thread, process,
  debugger again, then the job chain), after which "the kernel terminates the
  process". "applications running on Fuchsia have no ambient authority."

## Scheduler activations

The kernel allocates processors to address spaces, reports processor and
blocking events to the user-level scheduler by upcall, and never resumes a
stopped user-level thread itself [A1].

* A thread preempted in a critical section "is continued temporarily via a
  user-level context switch" until it leaves (pp. 66-67). A null fork costs
  37 µs on scheduler activations against 948 for Topaz kernel threads
  (Table IV, p. 71), but signal-wait through the kernel took 2.4 ms, "a factor
  of five worse than Topaz threads" (pp. 71-72).
* NetBSD 5.0 replaced them with 1:1 threads because "The SA implementation was
  complicated, scaled poorly on multiprocessor systems and had no support for
  real-time applications"; FreeBSD 7.0 made 1:1 libthr the default [A2]; the
  removal of FreeBSD's KSE is **unverified**. They "could not handle rare
  corner cases, due to the coupling of events to activations" ([U1] p. 117).

## Barrelfish

The multikernel: a CPU driver and a monitor per core, state replicated by
agreement protocols, user-level RPC over cache lines (URPC) between cores, and
processes as per-core dispatchers scheduled by upcall [B1].

* "View state as replicated instead of shared" (p. 5). From four cache lines
  per update "the RPC latency is lower than shared memory access", and one
  server thread "can perform twice as many updates per second as all 16
  shared-memory threads combined" (p. 4).
* URPC latency is 450 cycles against 424 for L4 IPC, with throughput 3.42
  against 2.36 messages per thousand cycles (p. 10). "queuing effects become
  very important in a purely message-oriented system ... performance anomalies
  due to extreme sensitivity to message queue lengths" (p. 17).

## Other systems

* **Theseus** [T1]: safe Rust in one address space at one privilege level,
  built from cells whose boundaries persist at run time; a live swap of the
  inter-task channel had a median downtime of 385 µs (p. 10), and recovery
  unwinds, restarts and reloads in stages (pp. 9-10). Of 13 faults injected
  into IPC paths it recovered from 11 and MINIX 3 from none; of the 0.083% of
  800,000 injected faults that caused visible failures it recovered from 69%,
  the rest mostly for "lack of asynchronous unwinding in Rust/LLVM" (p. 11).
* **RedLeaf** [R1]: a Rust microkernel, all in ring 0, with private heaps per
  domain, shared data as `RRef<T>` in a global heap, and proxies that unwind
  threads from crashed domains. Under KaffeOS shared objects were "potentially
  left in an inconsistent state", while Singularity's single ownership was "key
  for a clean and practical fault isolation model" (pp. 23-24); a crashed
  domain's regions are freed "without calling any destructors" (p. 26); "We
  trust devices to be non-malicious" pending IOMMUs (p. 25). A cross-domain
  call costs 124 cycles, seL4 IPC 834 (Table 1, p. 30); a block driver crashed
  every second cost 5% of read and 16% of write throughput (p. 34).
* **Biscuit** [C1]: a Go POSIX kernel with a fixed-size heap. "The longest
  single GC-related pause suffered by NGINX was 115 microseconds; the longest
  observed sum of GC delays to a complete NGINX client request was 600
  microseconds" (p. 89). Each system call "waits until it can reserve enough
  heap space to complete the call", a killer thread kills the process holding
  most resources, and "Lack of a way within POSIX for the kernel to gracefully
  revoke resources causes there to be no good solution in some out-of-memory
  situations" (pp. 93-95). GC took 34%, 19% and 9% of CPU with live data at
  0.66, 0.50 and 0.33 of the heap (pp. 99-100); "Go's garbage collector needs a
  factor of 2 to 3 of heap headroom to run efficiently" (p. 102).
* **Midori** (secondary source) [D1]: "Abandonment unapologetically tore down
  the entire process in an instant, refusing to run any user code while doing
  so"; a kernel bug abandons "an entire 'domain' (address space)"; Erlang
  supervisors were the model. It removed ambient authority, down to "no global
  function to read time"; per-process heaps "independently collectible" were
  "the most important architectural characteristic" for GC at scale.
* **HydrOS** [Y1]: one BEAM per core over a small kernel of about 24 hardware
  BIFs, drivers only in Erlang. "Failures (even at the hardware level) in one
  core will not affect other cores"; drivers are "Restartable on demand";
  "Processes have the same or fewer capabilities than their parents". A Hacker
  News comment calls the project abandoned (**unverified**).
* **GRiSP and Nerves** [N1]: GRiSP runs "Erlang and Elixir on RTEMS"; Nerves
  "uses the Linux kernel" and starts the runtime "as one of the first OS
  processes". Both keep a conventional kernel beneath an unmodified BEAM.
* **The eBPF verifier** [V1], the precedent for a validating loader, "simulates
  execution of every insn and observes the state change of registers and stack"
  along all paths and admits only whitelisted helper calls; CVE-2021-3490, a
  bounds-tracking bug, "could be turned into out of bounds reads and writes in
  the Linux kernel and therefore, arbitrary code execution".
* **CHERI on Morello** [X1]: bounded, tagged pointers whose "monotonicity of
  privilege ... is the essence of the compartmentalization"; memory safety
  costs "in the range of 0-5%", more on "very pointer heavy workloads";
  compartment switches are cheaper "by orders of magnitude" than process
  switches; the prototype "did not address Spectre-type speculation attacks."
* **Akaros** [U1]: applications must handle "the revocation of cores at any
  time -- even when the code is holding locks" (p. 1); "A preemption can come
  at any line of code in userspace" (pp. 116-118); "Threads are not part of the
  contract between the user and the kernel" (p. 160).
* **Arachne and Shenango** [Q1]: Arachne's arbiter "does not unilaterally
  preempt cores, since the core's kernel thread might be in an inconvenient
  state" and reclaims by force only after 10 ms; Shenango reallocates cores
  every 5 µs, each reallocation completing "in only 5.9 µs".
* **Spectre and language-based isolation** [W1]: "speculative vulnerabilities
  on today's hardware defeat all language-enforced confidentiality with no
  known comprehensive software mitigations ... we have shifted the security
  model of the Chrome web browser and V8 to process isolation."

## The Erlang runtime

The BEAM Book [O2]:

* "preemptive scheduling on top of cooperative scheduling": a process is
  suspended only at a function call or a receive, after `CONTEXT_REDS` (4000)
  reductions; C code "can not yield in the middle", which "can lead to an
  imbalance in the scheduler, and even starvation" (section 10.3). Run queues
  are per scheduler, balanced by stealing and migration (section 10.8).
* Each process has its own heap and "copying generational garbage collector"; a
  send copies the message into the receiver's mailbox or a heap fragment
  (sections 3.2 to 3.5). Binaries over 64 bytes are reference-counted off-heap
  and "stick around until the very last process stops referencing them"
  (section 11.2.6); literals are global until "their corresponding module is
  explicitly purged or reloaded" (section 11.2.13).

OTP 29.1.2 documentation [O1]:

* `max_heap_size`: "The size check is only done when a garbage collection is
  triggered"; exceeding it sends an "untrappable exit signal with reason kill";
  `include_shared_binaries` defaults to false.
* BeamAsm: "Anything from no difference to up to four times as fast is
  possible", at "about 10% more" code memory; for W^X "we map code twice: once
  with an executable page and once with a writable page."
* Secure Coding Guidelines: "All loaded code is assumed to be trusted. There is
  no built-in sand-boxing mechanism for running untrusted Erlang code." "a
  malicious BEAM module can do anything, including breaking the memory safety
  protections of the runtime system and crashing the virtual machine."
  "Excessive resource usage is not prevented by default." "All nodes connected
  through Erlang distribution are assumed to be trusted". Processes "can only
  affect other entities through the use of signals", which drivers and NIFs
  "may, of course, violate".

## Lessons

What the systems above show together, as facts with their sources.

1. **Privilege crossings, not safety checks, dominate the cost of isolation:**
   4.5-4.7% for Singularity's safety checks against 33-37.7% for ring crossings
   on an IPC-heavy benchmark, on x86 with untagged TLBs; tagged TLBs remove
   part of that cost (inferred). [S1; S2]
2. **One address space keeps no secrets.** Speculation defeats
   language-enforced confidentiality, so V8 moved to process isolation; RedLeaf
   and Morello leave side channels out of scope. [W1; R1; X1]
3. **An Erlang pid is ambient authority:** forgeable, and carrying send, link
   and exit together. Safe Erlang replaces pids with rights-carrying
   capabilities; Zircon and Midori have no ambient authority. [E1; Z1; D1]
4. **The BEAM loader is not a verifier.** OTP assumes loaded code is trusted; a
   validating loader puts a verifier in the trusted base, where its bugs become
   kernel exploits; Singularity forbids code loading instead. [O1; V1; S3]
5. **Killing needs deferral and region reclamation.** KaffeOS defers
   termination in kernel code, where exceptions would corrupt shared state;
   Singularity and RedLeaf reclaim dead domains by region; Theseus fails mostly
   for lack of asynchronous unwinding. [K1; S1; R1; T1]
6. **Shared state is where isolation breaks.** The BEAM shares
   reference-counted binaries and global literals; KaffeOS freezes shared heaps
   and charges every sharer in full; Singularity and RedLeaf use single
   ownership, so a crash leaves nothing half-updated. [O2; K1; S4; R1]
7. **Work for others is charged to the requester only where a mechanism does
   it:** seL4 MCS through the donated scheduling context, KaffeOS for
   allocations made on a process's behalf; Singularity notes multiplexed
   servers blur accounting. [M1; K1; S3]
8. **Heap exhaustion is designed in or not handled.** OTP prevents no excessive
   use by default and checks its heap limit only at GC; Biscuit reserves at
   system-call entry and still needs 2-3x headroom; LING reports BEAM crashing
   when memory is tight. [O1; C1; L1]
9. **Per-process heaps bound collection pauses,** as Singularity and Midori
   report, while Biscuit's single heap paused up to 115 µs; the BEAM's global
   tables (atoms, literals, ETS, the code index) lie outside that bound
   (inferred). [S1; D1; C1; O2]
10. **Preemption at arbitrary points breaks lock holders.** Scheduler
    activations needed lock-holder recovery and NetBSD dropped them; Akaros
    shows preemption strikes any line; Arachne reclaims cores cooperatively; JX
    bounds `preempted()` by verification; the BEAM preempts only at calls and
    receives. [A1; A2; U1; Q1; J1; O2]
11. **Systems that recover well fix each fault's blast radius in advance:**
    Midori abandons a process, or a domain on a kernel bug; Theseus recovers in
    stages; RedLeaf restarts drivers at 5-16% cost; Zircon kills after a fixed
    handler order. [D1; T1; R1; Z1]
12. **DMA is the hole in language safety:** the only one left in House, and
    trusted in JX and RedLeaf; an IOMMU, the SMMU on AArch64, is what confines
    it (inferred). [H1; J1; R1]
13. **An open, inspectable system needs visible boundaries.** Genera's tools
    rest on compiler-kept databases in a system with "no protected core", and
    its authors call the missing "keep out" signs a hazard. [G1; G2]
14. **Messages beat shared memory past a few cache lines, and queues become the
    bottleneck,** as Barrelfish found; the BEAM keeps per-scheduler run queues,
    and HydrOS and LING run one VM per core or domain. [B1; O2; Y1; L1]
15. **A JIT brings W^X and code generation into its trusted base.** BeamAsm is
    up to four times faster than the interpreter at about 10% more code memory
    and maps code twice; Dis's JIT ran 30-50% slower than C. [O1; I2]

## Sources

All accessed 2026-10-29.

* [S1] G. C. Hunt, J. R. Larus, "Singularity: Rethinking the Software Stack",
  ACM SIGOPS OSR 41(2):37-49, 2007, doi:10.1145/1243418.1243424, https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/osr2007_rethinkingsoftwarestack.pdf
* [S2] M. Aiken, M. Fähndrich, C. Hawblitzel, G. Hunt, J. Larus,
  "Deconstructing Process Isolation", MSPC '06, pp. 1-10, doi:10.1145/1178597.1178599, https://cs.uwaterloo.ca/~brecht/courses/702/Possible-Readings/oses/singularity-deconstructing-process-isolation-mem-system-perf-2006.pdf
* [S3] G. Hunt et al., "Sealing OS Processes to Improve Dependability and
  Safety", EuroSys '07, doi:10.1145/1272996.1273032, https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/EuroSys2007_SealedProcesses.pdf
* [S4] M. Fähndrich et al., "Language Support for Fast and Reliable
  Message-based Communication in Singularity OS", EuroSys '06, pp. 177-190, OSR doi:10.1145/1218063.1217953, https://www.microsoft.com/en-us/research/wp-content/uploads/2006/04/singsharp.pdf
* [P1] B. N. Bershad et al., "Extensibility, Safety and Performance in the SPIN
  Operating System", SOSP '95, pp. 267-284, doi:10.1145/224056.224077; read from Savage's copy, https://cseweb.ucsd.edu/~savage/papers/Sosp95.pdf
* [I1] S. Dorward et al., "The Inferno Operating System", Bell Labs Technical
  Journal 2(1):5-18, 1997; read from Vita Nuova's revised HTML copy (no DOI verified), https://www.vitanuova.com/inferno/papers/bltj.html
* [I2] P. Winterbottom, R. Pike, "The design of the Inferno virtual machine",
  IEEE Compcon 97 (venue per the Vita Nuova copy; the file is named hotchips.html, and no Hot Chips version was found), https://www.vitanuova.com/inferno/papers/hotchips.html
* [G1] J. H. Walker, D. A. Moon, D. L. Weinreb, M. McMahon, "The Symbolics
  Genera Programming Environment", IEEE Software 4(6):36-45, 1987, doi:10.1109/MS.1987.232087; read from a third-party OCR scan, https://cl-pdx.com/static/The-Symbolics-Genera-Programming-Environment.pdf
* [G2] Symbolics, "Programming the User Interface", Genera 8 documentation,
  page 1615, http://bitsavers.trailing-edge.com/pdf/symbolics/software/genera_8/Programming_the_User_Interface.pdf
* [L1] LING: repository `cloudozer/ling`, last commit bc97a26 (2015-10-12);
  erlangonxen.org Wayback snapshots 2013 to 2015; M. Kharchenko's site and CIF16 slides (2016): https://github.com/cloudozer/ling , https://web.archive.org/web/20131117061156/http://erlangonxen.org/blog/out-of-memory , https://maximk.github.io/ , https://www.slideshare.net/xen_com_mgr/cif16-rethinking-foundations-for-zerodevops-clouds-maxim-kharchenko-cloudozer-cto
* [E1] L. Brown, D. Sahlin, "Extending Erlang for Safe Mobile Code Execution",
  ICICS '99, LNCS 1726, pp. 39-53, doi:10.1007/978-3-540-47942-0_5; read from the authors' HTML version, https://web.archive.org/web/20180320023905/http://lpb.canb.auug.org.au/adfa/research/sserl/icics99.html
* [K1] G. Back, W. C. Hsieh, J. Lepreau, "Processes in KaffeOS: Isolation,
  Resource Management, and Sharing in Java", OSDI 2000 (PDF pages), https://www.usenix.org/legacy/events/osdi2000/full_papers/back/back.pdf
* [J1] M. Golm, M. Felser, C. Wawersich, J. Kleinöder, "The JX Operating
  System", USENIX ATC 2002, pp. 45-58 (PDF pages; p. 1 is the cover), https://www.usenix.org/legacy/event/usenix02/full_papers/golm/golm.pdf
* [H1] T. Hallgren, M. P. Jones, R. Leslie, A. Tolmach, "A Principled Approach
  to Operating System Construction in Haskell", ICFP '05, pp. 116-128, doi:10.1145/1086365.1086380, https://web.cecs.pdx.edu/~apt/icfp05.pdf
* [M1] A. Lyons, K. McLeod, H. Almatary, G. Heiser, "Scheduling-Context
  Capabilities", EuroSys '18, doi:10.1145/3190508.3190539, https://trustworthy.systems/publications/full_text/Lyons_MAH_18.pdf
* [Z1] Fuchsia documentation: Kernel Concepts, Handles, Rights, Job, Exception
  Handling, Port, VMO, Sandboxing, Security principles, `zx_job_set_policy`, `zx_job_set_critical`, `zx_task_kill`, https://fuchsia.dev/fuchsia-src/concepts/kernel/concepts and sibling pages
* [A1] T. E. Anderson, B. N. Bershad, E. D. Lazowska, H. M. Levy, "Scheduler
  Activations", SOSP '91, doi:10.1145/121132.121151; ACM TOCS 10(1):53-79, 1992 (read), doi:10.1145/146941.146944, https://flint.cs.yale.edu/cs422/doc/sched-act.pdf
* [A2] M. Rasiukevicius, "Thread scheduling and related interfaces in NetBSD
  5.0", 2009, https://www.netbsd.org/~rmind/pub/netbsd_5_scheduling_apis.pdf ; FreeBSD 7.0 announcement, https://www.freebsd.org/releases/7.0R/announce/
* [B1] A. Baumann et al., "The Multikernel: A New OS Architecture for Scalable
  Multicore Systems", SOSP '09, pp. 29-44, doi:10.1145/1629575.1629579, https://www.sigops.org/s/conferences/sosp/2009/papers/baumann-sosp09.pdf
* [T1] K. Boos, N. Liyanage, R. Ijaz, L. Zhong, "Theseus: an Experiment in
  Operating System Structure and State Management", OSDI '20, pp. 1-19, https://www.usenix.org/system/files/osdi20-boos.pdf
* [R1] V. Narayanan et al., "RedLeaf: Isolation and Communication in a Safe
  Operating System", OSDI '20, pp. 21-39, https://www.usenix.org/system/files/osdi20-narayanan_vikram.pdf
* [C1] C. Cutler, M. F. Kaashoek, R. T. Morris, "The benefits and costs of
  writing a POSIX kernel in a high-level language", OSDI '18, pp. 89-105, https://www.usenix.org/system/files/osdi18-cutler.pdf
* [D1] J. Duffy, Midori blog posts (secondary source), 2015 to 2016: "Objects
  as Secure Capabilities", "Asynchronous Everything", "The Error Model"; series index http://joeduffyblog.com/2015/11/03/blogging-about-midori/
* [Y1] S. Williams, "How to Build an OS in Erlang: A Whistle-stop Tour of
  HydrOS", Erlang User Conference 2017, http://www.erlang-factory.com/euc2017/sam-williams
* [N1] GRiSP, https://www.grisp.org/ ; Nerves, getting started,
  https://hexdocs.pm/nerves/getting-started.html
* [V1] Linux kernel documentation, "eBPF verifier" (Linux 7.3.0),
  https://docs.kernel.org/bpf/verifier.html ; CVE-2021-3490, https://cveawg.mitre.org/api/cve/CVE-2021-3490
* [X1] R. Grisenthwaite et al., "The Arm Morello Evaluation Platform", IEEE
  Micro 43(3):50-57, 2023, doi:10.1109/MM.2023.3264676; read from the Cambridge manuscript, https://www.repository.cam.ac.uk/bitstreams/c26b2575-71fc-4ed4-bd10-4a38114531bd/download
* [U1] B. Rhoden, "Operating System Support for Parallel Processes", PhD
  thesis, UC Berkeley, UCB/EECS-2014-223, 2014, https://www2.eecs.berkeley.edu/Pubs/TechRpts/2014/EECS-2014-223.pdf
* [Q1] H. Qin, Q. Li, J. Speiser, P. Kraft, J. Ousterhout, "Arachne", OSDI '18,
  https://www.usenix.org/system/files/osdi18-qin.pdf ; A. Ousterhout et al., "Shenango", NSDI '19, https://www.usenix.org/system/files/nsdi19-ousterhout.pdf
* [W1] R. McIlroy, J. Sevcik, T. Tebbi, B. L. Titzer, T. Verwaest, "Spectre is
  here to stay", arXiv:1902.05178, 2019, https://arxiv.org/abs/1902.05178
* [O1] Erlang/OTP 29.1.2 documentation: "BeamAsm, the Erlang JIT -- OTP 29.1.2
  (erts 17.1.1)", https://www.erlang.org/doc/apps/erts/beamasm.html ; `erlang:process_flag/2`, https://www.erlang.org/doc/apps/erts/erlang.html ; "Secure Coding Guidelines -- Erlang System Documentation v29.1.2" (not the EEF Security Working Group's separate "Secure Coding and Deployment Hardening Guidelines"), https://www.erlang.org/doc/system/secure_coding.html
* [O2] E. Stenman et al., The BEAM Book (last updated 2026-09-25), chapters 3,
  10 and 11, https://blog.stenmans.org/theBeamBook/
