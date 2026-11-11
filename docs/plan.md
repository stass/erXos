# erXos plan

The staged roadmap from an empty tree to protected Erlang domains, users
and a release build on QEMU `virt`, and then to storage, networking and
the first boards. Each milestone ends in a demonstration that a QEMU
transcript test, or on a board the board rig of M12, reproduces, and has
exit criteria that tests check. Where the design rests on a number nobody
has measured, or on a choice the user has not made, a decision gate
measures or asks, and decides. The architecture is
[design.md](design.md); open work outside this plan lives in `TODO.md`.

Ground rules:

* **A working system first.** Phase 1 brings the system up on a
  near-stock Fiasco: the boot image, ERTS as the system domain in user
  mode, the live machine, basic file systems and the Erlang command
  shell, with `liberx`'s Fiasco backend implementing the kernel
  interface over Fiasco's own calls and nothing of erXos's kernel
  semantics inside Fiasco. Security, robustness and scheduling
  efficiency are not demanded of Phase 1; a call the backend cannot
  offer refuses, a value it cannot measure reports unsupported, and no
  gap of Fiasco that erXos's kernel closes is plugged. Phase 1b carries
  the user-facing system further on the stopgap, behind the same
  interface, with every guarantee still deferred: domains and their
  connections, programs and pipes, the POSIX-lite first part, the
  browser and the desktop, drivers in their domains, storage and
  networking on QEMU. Each guarantee a Phase 1b item defers is a row of
  one list, [What Phase 1 defers](design-stopgap.md#what-phase-1-defers),
  naming the milestone that closes it, and `TODO.md`'s security residuals
  point to that list rather than copy it. Phase 2 builds erXos's
  kernel with every guarantee, boots the same boot image, and replaces
  the stopgap at parity over Phase 1 and 1b's system; everything that
  needs a guarantee lands on erXos's kernel alone
  ([design-stopgap.md](design-stopgap.md)).
* **A demo per milestone.** Every milestone ends with something a person
  can watch, and `make run` works at every commit.
* **Tests accumulate.** Each milestone adds transcript tests under HVF and
  keeps every earlier test passing; TCG runs only the deterministic-mode
  transcript and a boot smoke test. Exit criteria are tests, never
  inspection.
* **Two backends pass one test set.** Every `liberx` function lands with
  tests of its contract that the hosted and the Fiasco backends both
  pass, refusals included; track K's conformance suite, written from the
  design against the `erx` backend, grows from that set and decides the
  switch together with Phase 1's own tests.
* **The oracle runs on a schedule.** M0 verifies the test runner with focused
  cases and controlled pass, failure, skip, timeout and interruption checks.
  The complete stock reference runs are recorded before ERTS port changes
  begin. From M3 on, OTP's `emulator`, `kernel`,
  `stdlib` and `compiler` suites run on erXos, in the system domain until
  1b-A brings domains and in a test domain from then on, and are compared
  case by case with stock OTP 29.1.2 in the host's isolated Linux oracle
  ([design.md](design.md#testing-and-the-oracle)). A fast subset runs with
  `make check` on every change; the full suites at every major change (to
  the kernel or the stopgap, the scheduler, memory, the funnel and the
  connections' carrier, the adapter, the loader, or the build of OTP or
  musl) and at each milestone's exit. `make check-oracle` also runs musl's
  `libc-test`. A case that cannot run yet is never a pass: the run shows it as
  "cannot run" with its reason, and the milestone that brings what it needs
  must run it. Files arrive with `/tmp` at M3 and the file services of M4 and
  M6, peers with the domains and connections of 1b-A, sockets with the
  network service of 1b-G. The full oracle therefore closes on QEMU in
  Phase 1b.
* **Measure, then decide.** A gate records its measurements in a research
  record and its decision in the design document it shapes; the plan says
  where the gate sits and what it decides.
* **Cooperation earns its place.** The plain configuration (executors as
  ordinary threads) comes first; each cooperation feature lands behind its
  group flag with before-and-after numbers from `tools/erx bench`
  ([design-scheduler.md](design-scheduler.md#performance)).
* **Stopgaps sit behind seams and leave on parity.** A stopgap never leaks
  its formats. [Stopgaps](#stopgaps) names the milestone that replaces each;
  a third-party stopgap also has its `TODO.md` item, while a stopgap
  mechanism of erXos's own is tracked here alone. The replacement runs
  differentially against the stopgap over the test corpus, which for the
  kernel is Phase 1 and 1b's system's; every difference is a bug in the
  replacement, a
  documented improvement with a test, or a bug in the stopgap recorded as
  such.
* **Checks before the code they police.** The generators and the
  generated-tree tests, the stack proof and each chokepoint check land before or with the first
  code they constrain; every parser of untrusted input lands with its fuzz
  target.
* **Development builds run only trusted code** until M11, and say so in the
  boot banner.
* **Long-running commands are tracked.** Builds, QEMU guests, suites,
  benchmarks and external reviews run with standard input closed, output in
  a log and a hard deadline, as `gtimeout -k 10 SECS cmd ...`; every QEMU
  guest runs with `-no-reboot`, and a hung guest is killed, never waited on.
* **Numbers carry their conditions.** Every number records host,
  accelerator, QEMU version, compiler, flags, workload and baseline; TCG
  numbers are never compared with HVF or native numbers.
* **The closure holds after M11.** Every milestone and track that lands
  after M11 repeats M11's closure over what it adds (every fuzz target at
  its full budget, ASan, UBSan and TSan clean, every residual risk it adds
  reviewed, an external review), and a release build of any platform
  includes its work only after that.

## Overview

The plan has three phases. Phase 1, M0, M1, track H, M3, M4, M6 and the
shell of track S, brings the system up on the stopgap Fiasco. Phase 1b
carries the user-facing system further on the stopgap, in eight items
named 1b-A to 1b-H: M5's domains (1b-A), the programs of track S (1b-B),
track D's browser and QEMU kiosk (1b-C), track P's first part (1b-D),
M9's drivers in their domains (1b-E), track D's desktop and Plan 9's
programs (1b-F),
networking on QEMU (1b-G) and M13 on QEMU (1b-H), each with the backend
rows it needs and its guarantees deferred. Phase 2, track K, M7, M2, the
kernel parts of M5 and M9, the rest of track P, M8, M10, track Q, M11,
M12 with its boards and track D's last parts, builds erXos's kernel,
switches to it at parity over Phase 1 and 1b's system, and adds
everything that needs a guarantee on it alone. Track K's pilot starts
before Phase 1 is complete and runs beside Phase 1b, and its kernel in
full starts after 1b-A. Milestone numbers are
names; the table's order is the order.

| Milestone | Demo | New code (estimate) | Needs | Gate |
| --- | --- | --- | --- | --- |
| **Phase 1** | | | | |
| M0 The tree, the toolchain and the oracle | focused stock OTP 29.1.2 cases verify the offline Linux test runner; native Mac OTP supplies bootstrap tools; the frozen Fiasco set builds from the tree; every generated file regenerates unchanged | 4,000 lines of Ruby | | G0 |
| M1 The system boots on Fiasco | the near-stock Fiasco prints erXos's banner and starts `liberx`'s root entry as the root task under HVF; the root allocates, maps and reuses memory, runs threads with TLS and timed waits, runs a second task through a read-execute alias and ends it, takes an interrupt through the readiness interface, and ends the machine with a crash record on a stopped pet; the production image boots to the point where ERTS starts | 3,000 to 4,500 lines of C17 | M0, G0 | |
| Track H Hosted mode | the runtime runs as a Mac process under the sanitizers; once the Fiasco backend's rows between tasks have settled, domains and their connections run as Mac processes too, over the same backend rows as the stopgap's | 3,000 lines of C17 | M0 | |
| M3 The shell is the operating system | `1>` on the serial console, from ERTS in the system domain in user mode, started by the root task | 8,000 lines of C, 1,000 of Erlang | M1, track H | G3 |
| M4 The machine is an object | save in the editor on the Mac, run in the machine; follow a process to its source; ERTS and backend events on one timeline, the kernel's row unsupported | 10,000 lines of Erlang, 3,000 of Ruby, 2,000 of C | M3 | |
| M6 Immutable code, lasting data | the shell reads the release's files from an EROFS image on a QEMU disk; a file under `/data` survives a power cut | estimated in the subsystems' design documents | M4 | |
| Track S The command shell | `ps -m \| grep erx` in a shell with rc's language, printing FreeBSD's text | 6,000 lines of Erlang, 4,000 of C17 for the track, programs included | M4 | |
| **Phase 1b** | | | | |
| 1b-A M5 on the stopgap | spawn into a sandbox domain with a link, crash it, get `{domain_down, D, crash}`; kill a domain mid-burst and watch its end arrive after its last messages; kill the system domain and read its crash record after the reset; every guarantee deferred | 9,000 lines of C17, 6,000 of Erlang for M5, its kernel interface carried as backend rows in the Fiasco backend, and in the hosted backend where cheap (2,000 to 4,000 lines of C17, a guess until the first rows land) | Phase 1 | G5, provisionally |
| 1b-B Track S, programs | `find /tmp/logs -type f \| xargs tail -n 1` through toybox's applets as ports of the session, and `within` confining a program to one grant, on the stopgap | in track S's figure | 1b-A | |
| 1b-C Track D, parts 1 to 3 | `tools/erx web` shows a QEMU guest's records, kernel log and traces in a browser over the host link, with no network or display device; one application's user interface in the browser, and the same interface on a QEMU `virt` kiosk drawn by LVGL, with no login | estimated per part before it starts; the designs give no figure | 1b-A and the session domain, 1b-B's first slice; part 3 also 1b-E and 1b-B's sub-space ports | GW |
| 1b-D Track P, the first part | a UNIX program recompiled unchanged makes pipes, spawns children with inherited descriptors and waits for them, on the stopgap | 10,000 to 15,000 lines of C for the track | 1b-B's session domain, sub-space ports and pipes, not toybox's applets | GP, provisionally; the G6 baseline |
| 1b-E M9 on the stopgap | a block transfer runs while the block driver process is killed; its supervisor resets the device and restarts the driver, and the shell never notices; drivers run in the storage, network and display domains over virtio-mmio, unconfined | 3,000 lines of C17, 5,000 of Erlang for M9, of which the PCIe enumerator and the MSI frame's driver are its kernel part's | 1b-A; littlefs's sub-space port also 1b-B | G9's measurements, deciding nothing |
| 1b-F Track D, parts 5 to 7 | a QEMU `virt` desktop whose terminal windows run the shell, the same user interface term as on the web, and acme and sam editing a file | estimated per part before it starts | 1b-E and 1b-C; part 7 also 1b-D | |
| 1b-G Networking on QEMU | the network domain carries UDP echo and a TCP bulk transfer to a Linux peer through the packet-path prototype, on QEMU under HVF | estimated in the network service's design document | Phase 1: the network driver and stack run in the system domain, as M6's block driver does, until 1b-E moves them into the network domain | GN-QEMU's baseline, deciding nothing |
| M14 erXos's network stack, on QEMU | TLS, SSH and distribution sessions run over erXos's own TCP/IP stack, written in Erlang from FreeBSD's, on QEMU in 1b-G; the boards follow with M12 | estimated in its design document | 1b-G's prototype | G14 |
| 1b-H M13 erXos's F2FS on QEMU | erXos's F2FS, written in Erlang, keeps a QEMU disk's files through power cuts and its images mount in the Linux guest; on the Pi 4 with M12 | estimated in its design document | M6 | G13 |
| **Phase 2** | | | | |
| Track K erXos's kernel | the pilot, then the kernel, booting Phase 1 and 1b's boot image and passing the conformance suite | 25,000 to 40,000 lines of C17, of which the capability core and the budget core exist; the pilot calibrates the figure | the pilot: M0, starting before Phase 1 is complete; the kernel in full: 1b-A | GK1, GK2, GK3 |
| M7 The stopgap leaves | erXos's kernel boots Phase 1 and 1b's system and runs every test and benchmark it ran on the stopgap | integration | track K | GK3 |
| M2 The execution contract holds | a native test domain and a hostile domain share four CPUs by grants; no wakeup is lost; a blocking call from an executor is refused | 4,000 lines of C17 | M7 | G2 |
| M5's kernel part | a hostile runtime attacks a neighbour's funnel for ten minutes without effect; a domain killed under load gives every charge back to its principal's budget | in track K's figure | M2 | G5, confirmed |
| M9's kernel part | the drivers' restarts over virtio-pci with MSIs, each device's DMA confined behind the IOMMU, and the PCIe domain alone reaching configuration space | the PCIe enumerator and the MSI frame's driver, within M9's figure | M7 | G9, then G6 |
| Track P, the rest | a UNIX program recompiled unchanged pipes, polls, spawns children and takes `SIGINT` | in track P's figure | track P's first part; catchable signals the stopgap's vCPU row or M7 | GP |
| M8 Cooperation earns its place | the ladder from plain threads to full cooperation, measured on seven workloads, with each feature kept or dropped by its numbers | 4,000 lines of C17 and C | G6 | G8 |
| M10 Users without a container runtime | two users, two domains, one runs out of memory or CPU alone | 4,000 lines of Erlang | M8, M9's kernel part | |
| Track Q The second tier | toybox's `sh` runs a script with subshells, `vi` edits a file and `less` pages a log in a terminal session, and a dynamically linked program loads a library with `dlopen` | the programs' estimate in [design-programs.md](design-programs.md#performance), and the session's shared mappings, an estimated 3,000 lines of Erlang; the kernel's part is track K's | track P, M7 | GQ |
| M11 Security closure | a release build without the development banner, on erXos's kernel, with an Erlang driver behind an IOMMU window; one flipped byte of an EROFS image fails only the reads of its block | hardening | M10 | |
| M12 Storage, networking, boards | a Raspberry Pi 4 boots erXos from its SD card, keeps its files through power cuts, and takes a system update whose trial survives a power cut | estimated in the subsystems' design documents | M11 | G12, GN-board |
| Track D, parts 4 and 8 | a Raspberry Pi 4 kiosk; the web front end on the network | estimated per part before it starts | part 4: part 3 and M12; part 8: part 2, M10, M11 and 1b-G | GD, with part 4 |

The order reaches a usable system first:

* Phase 1 boots Fiasco near-stock and puts `liberx`'s backend on its
  calls, in increments a transcript test checks each: boot, memory,
  threads, a second task, an interrupt, the production image.
* The shell runs on ERTS with only the changes it cannot run without,
  hosted first; the live machine follows at once, because it is the
  product's identity and the instrument every later milestone is debugged
  with; then files from EROFS and littlefs, and the Erlang command shell.
* Phase 1b stands further on the stopgap, so that every item is a demo a
  person can watch before erXos's kernel exists. The order puts the
  demos a person sees soonest first. Domains over connections come first
  (1b-A), since every later item is a domain or runs in one; then
  1b-B's first slice, the session domain; then drivers in their own
  domains (1b-E), with the storage domain, and networking on QEMU
  (1b-G), which starts at once in the system domain, as M6's block
  driver did, and moves into the network domain with 1b-E; then the
  web on the developer's host over the host link, which needs no device
  on the machine (1b-C's parts 1 and 2); then the kiosk on QEMU `virt` drawn by LVGL
  (1b-C's part 3), with 1b-B's sub-space ports, which run the LVGL
  program. Programs as ports of their sessions over pipes and the first
  part of the POSIX personality (1b-D) follow, with toybox's applets, the
  rest of 1b-B, after 1b-D; gate G6's baseline records the result on the
  stopgap and decides nothing. The desktop with terminal windows (1b-F)
  comes after all of these, and last the boards' panels and the network
  front end. The backend grows the rows these need behind the unchanged
  interface, and the guarantees they would rest on are recorded as
  residuals, not built.
* Beside that path: BeamAsm beside 1b-A, and erXos's F2FS on QEMU (1b-H)
  at the lowest priority, whenever capacity is idle. The network stack's
  host-first packages run beside everything, since they need no guest.
* Track K's pilot starts before Phase 1 is complete and runs beside
  Phase 1b; erXos's kernel in full follows 1b-A, written from its design
  documents, which neither phase changes.
  It boots the same boot image and switches at parity over Phase 1 and
  1b's system (M7); the execution contract (M2), the kernel parts of M5
  and M9 and gate G6 then land on it, and G6 measures the result before
  anything more is built on it.
* Everything after that lands the same way: the cooperation features,
  users, the second tier, the security closure, and then the boards with
  their storage and networking.
* Storage on the boards stands on littlefs first; erXos's F2FS, written in
  Erlang, replaces it at parity, decided on QEMU in 1b-H. Networking has
  no stopgap stack: erXos's network stack, written in Erlang by
  translating the logic of FreeBSD's `netinet` and `netinet6`, is the
  network service from its first release, accepted against FreeBSD's
  packetdrill tests and a FreeBSD guest; a prototype of its packet path is
  measured on QEMU as a baseline (gate GN-QEMU), and whether TCP's fast
  path needs native code is decided on erXos's kernel (GK3), which the
  Pi 4 confirms at M12.

**Effort.** The estimates are sizes of new code, derived from the design
documents and from comparable components; they order and scope the work
and are not dates. Agents write most of the code; the verification,
review and decisions around it set the pace. Gate GK1 measures that pace on
a real piece of the kernel and converts sizes into time for the rest of the
plan.

## First integration checkpoint

In Phase 1b, after track S's shell, on the stopgap, build the domain and
connection path of M5 together with the inspection M4 brought. This is
the smallest coherent demonstration of domains:

* boot the root task and the system ERTS under HVF, with the
  trusted-code development banner;
* create one application domain from a pinned release through the domain
  library, give it one facet, and exchange a bounded request and reply
  over its connection to the system domain;
* inspect its pid, budget, grant, connections, exports and reported state
  through the same schema used by the console;
* exhaust or crash that domain and observe its end, `{domain_down, D,
  Info}` on its domain pid, its connection taken down and every charge
  back in its principal's budget, reported `unsupported` on the stopgap
  and checked at M7, without losing the system shell;
* disconnect two introduced domains, observe `noconnection` on everything
  across their connection, introduce them again and complete another
  operation.

The checkpoint uses plain scheduling and the interpreter. Full tracing,
BeamAsm, host-watch loading, the command shell, POSIX programs and durable
storage are not prerequisites for it. They retain their target designs
and milestone exit criteria; this ordering does not mark M4 or M5 complete
or trim the architecture to the demonstration. The checkpoint admits
trusted code alone. Phase 1 and 1b's system is the switch's workload, and
the checkpoint is its first demonstration of domains.

## Simplification experiments

Experiments decide implementations behind the accepted seams. They do not
silently weaken authority, accounting or compatibility contracts. Every
result records the required host, accelerator, toolchain, workload and
baseline conditions; unknown or unsupported results stay explicit.

| Gate | When | Comparison and required evidence | Decision |
| --- | --- | --- | --- |
| GP, programs and pipes | track P, in hosted mode first and under HVF on the stopgap before the first part of track P is complete; the stopgap's numbers are provisional, since each object a program's start makes is one request to the backend's root service there | a program's start from the session's `spawn` to its `main` (`tools/erx bench spawn`) against the budget of [design-programs.md](design-programs.md#performance); a `make`-shaped workload of many short children over pipes with a paused pager, and `tools/erx bench pipe` with one writer and with 256 writers; latency, throughput, memory per program and per pipe, and the session's Erlang work per request | the channel's and the data area's defaults, completion batching in the handler, whether the pipe server keeps one ring per write end ([design-pipes.md](design-pipes.md#the-ring)); whether a program's start needs a cheaper path than one kernel call per object is decided at GK3, on erXos's kernel |

GQ also measures the fill and the write-back cost of the session's shared
mappings with `tools/erx bench mmap`
([Track Q](#track-q-the-second-tier)). Tracks P and
Q record a named application corpus with expected behavior and deliberate
differences, so compatibility work is driven by programs the system is
intended to run.

Before the connections and the domain library run under QEMU, their host
models run whole: one lane under every interleaving of writes, reads and
published wake positions; one connection whose peer ends, with the drain
and deletion only after each party has unmapped or ended; a domain's
creation with a failure injected at each step and its undo; and the
funnel's verdict table over
frames that have and lack each right
([design-domains.md](design-domains.md#verification-and-testing),
[design-system.md](design-system.md#verification-and-testing)). These are
implementation acceptance obligations; documentation review is not
evidence that they have passed.

## Generation work

[Generated interfaces and representations](design-generation.md) owns the
sources, outputs and validation rules. Shared definitions generate their
C/Erlang/Ruby bindings and factual reference tables. Policy, ownership and
recovery stay in handwritten pure cores, checked against independent
models and oracles. Each extension lands with its first consumer rather
than building every later service before the usable slice.

| Work | When | Required result |
| --- | --- | --- |
| Declaration model and generation checks | M0 | explicit ABI fragments with one qualified type/name namespace; complete-input validation, deterministic generation into the build tree, with a test that the tree depends only on its recorded inputs and an ASCII refusal; typed layouts and assertions; status/errno/fault/signal mapping infrastructure; valid-input builders, boundary mutations and fuzz entry points alongside each parser; invalid-schema tests, and refusal of a file checked in or edited at a generated output's path |
| Startup from the packed manifest | M3 | the root task and `erx_manifest` read the system domain's records and its console device from the packed manifest through the generated readers; no second compiled configuration table |
| Inspection and host-facing service bindings | M4 | `abi/inspection.txt` generates builders, C/Erlang/Ruby types/validators, path/field/status/unit tables and shell/host/`/proc` projections; host-exposed service operations generate Ruby clients; independent tests reject unknown keys and reply mismatches and preserve each status/reporter; generated docs and fuzz scaffolding land with the interfaces |
| First generated service interface and the rest of the startup descriptors | 1b-A | console/service operations generate C/Erlang clients, admission/dispatch and bounded replies with scope policy in the handler; source checks refuse bypasses; the checked manifest's packed descriptors supply boot order, configured domains' devices, configured facets and watchdog liveness |
| Cross-domain service and protocol consumers | 1b-A and each later service | generated serving paths authenticate lane origin, check the live facet scope and bound input/output before callbacks; hostile tests exercise forged origins, stale handles, denied targets and restricted inspection fields; the 9P profile keeps its independent standard oracle |
| Command catalogs | track S | release metadata generates names, help and required facets, checked against callbacks without running target code; tests preserve name conflicts/precedence and bind metadata to loaded code across replacement and publication failures; a catalog grants no authority |
| Contextual error mappings and program interfaces | track P | generated translations cover every exposed status/error in its operation context, and fault/signal mappings cover every fault; compare numbers and behaviour against the selected musl/OTP and protocol oracles; raw kernel-call stubs still return status without setting errno |
| Typed diagnostics | events as they land from M1, full inspector/host consumers at M4; driver events with M9 | ABI log/trace declarations generate emitters/readers and typed field/unit tables; release/development projections and sink escaping have independent negative fixtures; device accessors and trace readers keep their original concurrency rules |

Every generated decoder is fuzzed through the production entry point.
Generated inputs and round trips never replace independent byte fixtures,
external behavioural oracles or TLA+/TLC models. The build checks the same
style, ASCII, bounds, stack and chokepoint requirements in generated source
as in handwritten code. A failed schema check publishes no partial output.

## Verification work

[Protocol verification](design-verification.md) owns the method and tool
boundaries. TLA+/TLC is selected for protocol models, with OpenBDB's JVM,
`TLA_TOOLS_JAR`, good/broken configuration roster and invariant mapping
approach. The runner is Ruby behind the top-level build. Models and
concrete tests remain separate evidence; a passing abstract model does
not establish correctness of its mechanism or implementation.

| Work | When | Required result |
| --- | --- | --- |
| TLC setup | M0 | `make check-tla`, separate from `make check`; jar version/hash and JVM setup; private run directories, deadlines, complete expectation roster, caching with an uncached mode and runner failure tests |
| Connection model and implementation mapping | 1b-A, before connections run under QEMU | TLC checks peer death, ordered delivery, unmapping and object retirement, including distinct peer incarnations; host tests cover the lane and teardown cores and failure traces; weak-memory ordering stays with `herd7` and conformance tests |
| CBMC pilot | track K's pilot, beside Phase 1b, before GK2 | check actual C arithmetic, allocation failure and retirement with explicit input and unwind bounds; detect seeded defects; report unsupported constructs, cost and assumptions; adopt further use only if it adds useful evidence at maintainable cost; existing GK1/GK2 tests remain required regardless |
| Host-link model and implementation mapping | M11, before the release build's host link is accepted | TLC checks session replacement, duplicate calls, expiry and credit; host traces check the actual pure core against an independent oracle; every invariant maps to a concrete check |
| Update model, mechanism and implementation mapping | M12, before accepting the slot writer and update service | the model covers committed and spare slots, healthy trial and power loss, every durable boundary, torn record, reset count, firmware trial outcome and failure in the storage contract, with targeted broken configurations and reachability witnesses; run TLC uncached; replay counterexamples as host regressions and QEMU crash tests; record the board/firmware assumptions and actual conformance evidence |

A selected tool missing from a requested gate fails with a diagnostic;
no gate silently skips it. Incomplete searches, timeouts and unsupported
results remain explicit and fail acceptance. The CBMC pilot decides
additional tools, not whether existing security properties are enforced.
The plan does not introduce a general state-machine generator or require
SPIN, Alloy or a new property-testing dependency.

## M0: The tree, the toolchain and the oracle

**Goal.** The tree builds offline from pinned sources, the oracle runs in
an isolated Linux container on the development host, native Mac OTP supplies
the bootstrap compiler, the harness can boot and judge a guest under both
accelerators, and every generated file has its generator.

**Demo.** `make fetch` downloads and verifies every pinned source and the
oracle's OCI toolchain image; `tools/erx oracle build` builds stock OTP
29.1.2 for Linux in both flavours without external networking;
`tools/erx oracle run emulator --suite binary_SUITE --case deep_bitstr_lists`
runs a focused stock case and stores its result; `tools/erx build fiasco`
builds the frozen Fiasco set
from `fiasco/` and `tools/erx qemu --accel tcg` and `--accel hvf` boot it
on `virt-11.1` to Fiasco's own banner; `make check` regenerates every
generated file and finds it unchanged.

**Scope.**

* The skeleton: the top-level `Makefile`; `tools/erx` in Ruby, with a
  deadline runner that starts subprocesses with argument vectors, runs them
  under `gtimeout -k 10`, and kills their process group on expiry; `make
  check` with the ASCII check.
* `deps.lock` and `make fetch`: pinned URLs and SHA-256 hashes, unpacking
  into separate directories under `build/third_party/`, plus the oracle's
  platform-specific OCI image pinned by manifest digest in the local engine.
* Imports, each with its licence notices and an `ORIGIN.md` recording the
  repository, the release or commit, and the SHA-256 of the import and of
  every file in it:
  OTP 29.1.2 into `otp/`, musl 1.2.6 into `musl/`, and into `fiasco/` the
  frozen Fiasco set of
  [design-kernel.md](design-kernel.md#the-current-implementation-the-modified-fiasco)
  with its excluded parts removed; a licence scan of the Fiasco set and the
  link closure of `bootstrap` and `sigma0`, recorded.
* The notices: every imported file's licence in its `ORIGIN.md`, from its
  SPDX header or, where it has none, from the import's review, marked as
  reviewed; the build check that a changed file of an imported tree
  carries erXos's change notice; the packer's provenance check and its
  licence allowlist over each image's closure, a slot's boot partition
  included; each check with its seeded-violation test; and the packer's
  `NOTICES` file ([design.md](design.md#licences-and-notices)).
* The oracle: stock OTP 29.1.2 built from the pinned tarball with its own
  `configure`, in both flavours, and a Ruby tool that runs OTP's suites in
  the [offline Linux context](design-host-oracle.md) and records results
  case by case. M0 verifies this tool with representative cases and controlled
  outcome fixtures; exhaustive suite runs are an ERTS-port prerequisite,
  not an M0 exit condition. Native macOS builds supply bootstrap tools and
  separate
  native performance baselines; they do not stand in for Linux suite results.
* The QEMU harness: QEMU `virt` as
  [design-platforms.md](design-platforms.md#qemu-virt) configures it under
  both accelerators, `-no-reboot`, serial output in logs, named lines
  awaited under named deadlines, transcripts compared with expected ones.
* The generators and the generated-tree tests: `abi/erx_abi.txt`, its explicit
  inspection/service fragments and `abi/arch/aarch64.txt`, with the shared
  declaration model, input/output inventories, generated reference tables
  and test/fuzz scaffolding of [Generation work](#generation-work), and
  their generator (decoders for the kernel,
  calls for each `liberx` backend, the layouts of lanes, frames, the boot
  information page, the crash record and the system manifest with its two
  readers, a C one and the Erlang module `erx_manifest`, a Ruby module for
  the packer);
  the CMSIS-SVD generator, whose register accessors the device NIF alone
  may reference; the system-register extractor; `abi/terminal.txt`; and
  the architecture-term check, `make check-arch-terms` over
  `hw/arch_terms/aarch64.txt`, with its seeded violation
  ([design-kernel.md](design-kernel.md#chokepoint-checks)).
* The boot-image format: test tooling writes deterministic `ERXPACK`
  version 2 structural fixtures with `NOTICES`, checked by the host-built
  C17 validator and its fuzz target. Production `tools/erx pack` arrives at
  M1, with the Phase 1 manifest check, as specified below.
* The TLA+/TLC runner and its tested expectation classification, private
  work directories and hard deadlines, `make check-tla` as a separate gate,
  tool version/hash pin and setup diagnostics
  ([Verification work](#verification-work)).
* `tools/erx bench`, recording every condition, with the host baselines on
  OTP 29.1.2.

**Structural image evidence.** M0's reproducibility output is labelled a
**structural test fixture**, not an admitted boot image. It contains a valid
non-JIT native root executable and a system manifest selecting native
partial boot, with zero configured and zero partial-boot child domains.
The fixture uses the canonical serializers and actual binary, executable
and provenance validators. Its report names their results separately and
records `root_startup = unsupported`, `policy_admission = unsupported`
and `child_plan_instances = 0`. The empty child set requires no child
planner call; it supplies no evidence about the initial root's stack,
UTCB, kernel objects, private image memory or bootstrap allocations.

Only test tooling writes these fixtures. They carry no new wire flag and
cannot construct the production `Admitted` value or bypass its publisher.
Production packing waits for M1's manifest check, whose root startup rule
stands in for the real initial-root feasibility/charge plan until Track K.
The root image's checked private-memory lower bound is still enforced;
a sufficient declared baseline alone is not a startup proof. The separate
M0 guest demo boots the frozen Fiasco set to its banner and does not claim
to execute erXos's root interface.

Independent populated binary fixtures exercise every manifest record and
the C, Erlang and Ruby structural readers without claiming policy
admission. Track K's first part supplies the production initial-root
bootstrap/charge plan
and `erx_dom_plan_configured` for both host admission checks and runtime
creation. Any unavailable required sizing, planning or service consumer
fails as unsupported. There is no temporary planner, weakened admission
path or reduced target manifest format.

**Exit criteria.** `make check` passes offline after `make fetch`; the
oracle records a focused Linux stock case and correctly reports controlled
passes, failures, skips, timeouts and interrupted/incomplete runs. It proves
loopback peer operation and absence of external networking, and removes
its container including daemonized test children on success or cancellation;
the stopgap boots to Fiasco's banner under HVF in the harness; a
build twice from clean gives identical structural `ERXPACK` fixtures, with
startup and policy admission explicitly unsupported; the fuzz target of the
boot-image validator runs its budget clean.
The TLC runner's tests pass, including targeted expected failures, wrong
properties, parser errors, incomplete runs, cache invalidation and empty
filters; the separate `check-tla` entry point reports missing tools as an
error and performs no network access. Generation rejects invalid schemas
before publishing output, regenerates the tree when an input or output
changes, and refuses a generated file checked in or edited. Independent fixtures check generated parsers and mappings.

**Gate G0.** The import: the licence scan and link closure of the Fiasco
set, which name the GPL-headed files the stopgap keeps
([design.md](design.md#dependencies)); since `kobject_rpc.h`, which every
build includes, is one of them, any distribution outside the project, in
source or binary form, waits for erXos's kernel, as CLAUDE.md's rule for
stopgaps requires. `lld` installed.

## M1: The system boots on Fiasco

**Goal.** A near-stock Fiasco boots erXos's boot image and starts
`liberx`'s root entry as the root task, and `liberx`'s Fiasco backend
gives, over Fiasco's own calls in user mode, every function that ERTS,
musl, the device NIF and the test tasks need
([design-stopgap.md](design-stopgap.md)).

**Demo.** The boot image boots through `bootstrap`; the kernel prints
erXos's banner and `development build: trusted code only` and starts the
root task; in a partial boot the root allocates, maps, protects, releases
and reuses memory, runs threads with TLS, timed waits, park and wake, exit
and join, runs a second task that executes code through a read-execute
alias and ends with a status, takes the UART's interrupt and a software
interrupt through the readiness interface, and ends the machine with a
crash record when a pet stops; the production image boots to the point
where ERTS starts. All under HVF, one and four CPUs.

**Scope.** Fiasco built near-stock from the fork, with `sigma0` and
`bootstrap`, the two banner lines, no serial input or JDB entry on the
console; `bootstrap`'s loader for the ERXPACK image; the root entry as
the root task, reading the manifest through its generated C reader; the
backend: the physical pool from `sigma0` in the root's pool window, the
range table, the VM calls and `erx_space_protect`, shared objects with the
JIT alias, physical and contiguous objects with the DMA address, IRQ
objects bound to a group's dispatcher with the ready list and
`erx_group_take_ready`, threads with one semaphore each and TLS set by the
start trampoline, park and wake under the group's park lock, the umtx
table, exit through each task's reaper, the test-task launcher over
`elf_plan.c` with the root service, one thread that serves a task's calls
and receives its faults, the crash record and the machine's end, the
watchdog thread,
the time page, entropy and the debug log over the log capability; the
generated encoder and decoder of the root service, with the decoder's fuzz
target; the Phase 1 manifest check in the packer
([design-stopgap.md](design-stopgap.md#the-phase-1-manifest-check)), whose
root startup rule stands in for the production planner until track K
brings it; the chokepoint that confines Fiasco's headers and capabilities
to `liberx/backend/fiasco`, with its seeded violation; the hosted
backend's matching functions and refusals.

**Exit criteria.** Each demo step is a transcript test under HVF;
a page committed, written, decommitted and committed again reads zeros; a
page protected to no access and back reads its contents unchanged, and a
stack made through `PROT_NONE` works; the pool's count returns to its
value before a task ran; a stack and a UTCB slot are reused under a join
loop; a touch of a decommitted page, a fault of the root and a stopped pet
each end the machine with a crash record on the console whose cause names
them; a fault in a test task ends the task with its record while the
machine continues; the umtx table's and the park protocol's TSan models,
the park protocol's check of a trigger between the empty check and the
park, and the range table's host tests pass; every function of the backend
has a test that the hosted backend passes with the same result, refusals
included; `make check-reproducible` passes on the production image; the
fuzz targets of the root service's decoder, the crash record's reader and
the manifest's C reader run their budgets clean; a Fiasco header or
capability outside the backend fails the build.

## M2: The execution contract holds

**Goal.** The runtime contract holds on erXos's kernel, with the smallest
runtime and under attack, before domains' guarantees build on it (M5's
kernel part).

**Demo.** Booted with a partial boot, the root task builds two native
domains through the domain library: one runs the contract test program,
four executors that park and wake over rings in shared memory and pass a
thousand messages a second among a thousand tasks of the program's own;
the other is hostile, spinning on every executor, signalling, parking
with stale epochs and calling blocking operations from executors. The
test domain keeps its grant; no wakeup is lost; every blocking call from
an executor returns `ERX_EWOULDBLOCK`.

**Scope.** Groups in configuration C1: grants with quota, period, cpuset
and capacity, the group tree, charging and throttling by draw quanta,
refill cohorts, the status area's capacity and usage,
`erx_group_configure` and its replacement of a grant, the deletion of
groups; the contract test program in `liberx`'s conformance suite, which
every later native test domain builds on; the dispatch-model
microbenchmarks.

**Exit criteria.** A group capped at 30% stays within its quota per period
to one draw quantum per CPU, at periods of 1, 10 and 100 ms (E-S7), meeting
the accuracy of [design-scheduler.md](design-scheduler.md#performance);
the test domain's executors
resume exactly where they were preempted (S1, checked by a test that
preempts at every instruction of a loop in deterministic mode); the storm
test of the park protocol passes on four CPUs under HVF; a group
of zero quota with 1,000 throttled threads costs each CPU one timer expiry
and one failed draw per period; a space whose group's quota is zero, or
spent, still posts its exit record once its threads have finished their
calls (K18); the refill and grant-replacement host tests pass.

**Gate G2.** Measures the early form of E-S2: a switch between two kernel
threads of one space and of two spaces, an IPC round trip through a gate,
and park and wake, under HVF; and E-S4's FIFO wake latency. The stopgap's
measured costs (an IPC of 51 to 89 ns, inferred from an emulated counter)
set the floor that a runtime's own switching must beat by an order of
magnitude; the full comparison with ERTS's processes is G5's. It also
measures E-S10, the blocking calls the executor rule refuses across OTP's
suites in the system domain. Decides: whether park, wake and the FIFO
wake latency meet E-S4's hypotheses, so that the two-level model stands
on erXos's kernel; if they do not, the design returns to the user with
the numbers before M5's kernel part builds on the contract; and which NIFs
move to
dirty schedulers.

## Track H: Hosted mode

Before modifying ERTS for the port, record the complete stock OTP 29.1.2
`emulator`, `kernel` and `stdlib` reference runs in interpreter and JIT modes.
Keep case identities, outcomes, skips, environment details and incomplete
records explicit. These reference runs are required for the ERTS comparison;
they do not block M1.

`liberx`'s hosted backend implements the kernel interface inside a macOS
process: spaces are the process, threads are pthreads, memory objects are
`mmap`ped regions, umtx waits are `os_sync_wait_on_address`, and groups and
parking keep the epoch protocol
([design-runtime.md](design-runtime.md#liberx)). From M3 on, ERTS's port
runs hosted first, under ASan, UBSan and TSan, and `lldb`. 1b-A targets QEMU: through 1b-A the hosted backend stays one
process, and gains the rows 1b-A needs only where they are cheap there.
Its multi-process form, in which several domains run as Mac processes with
their lanes in shared regions and the domain library drives the hosted
interface, comes once the Fiasco backend's rows between tasks have settled;
it carries those rows and no device row, since a hosted runtime has no
devices, and gets its design, reviewed as a design, before its code
([design-stopgap.md](design-stopgap.md#the-hosted-backend)). It is a
planned feature in [TODO.md](../TODO.md). QEMU remains authoritative.

## M3: The shell is the operating system

**Goal.** ERTS runs as the system domain in user mode on the contract,
started by the root task, with only the changes it cannot run without.

**Prerequisite.** The complete stock reference runs described in
[hosted mode](#track-h-hosted-mode) are available before the ERTS port
changes.

**Demo.** `1>` on the serial console; the shell evaluates, line editing
and history work, and `erlang:processes()` lists the system domain's
processes; an idle machine shows every executor parked.

**Scope.** The root-task entry's full boot, which builds the system
domain's memory, threads and runtime group from the system manifest and
starts ERTS on a system release whose manifest names no other domain
([design-system.md](design-system.md#the-root-task)); the group carries
the executors' parking and the interrupts' readiness, and Phase 1 enforces
no grant on it ([design-stopgap.md](design-stopgap.md#the-call-table));
the system manifest, the one file the build packs into the boot image to
configure the system, with its Erlang reader, `erx_manifest`, and the
fuzz target of that reader, read from the packed manifest's records
([Generation work](#generation-work)); the Phase 1 manifest check in the
packer, as
[design-stopgap.md](design-stopgap.md#the-phase-1-manifest-check) gives
it, with no property added to it in Phase 1; the
interpreter image, the runtime image that the system domain, the command
domains and deterministic mode run; the adapter's first five changes
(executors and workers, sleep over `erx_park`, wake over
`erx_executor_wake`, no busy waiting, the safe point with capacity), with
no cooperation flag enabled
([design-runtime.md](design-runtime.md#scheduling)), among the 41 edits
in 41 files that ERTS's own files take in all, of which M3 makes only
those the shell needs
([design-runtime.md](design-runtime.md#the-edits-outside-syserxos));
threads, memory, time, files and crash handling in `sys/erxos`; files
are the release file system, the namespace's mounts, the file protocol's
frame profile with its term grammar generated from `abi/erx_abi.txt`,
`erx_fs`'s core (the grant process, fids and their owners, open files
with their owners, `lcreate`'s create-or-open, and `write` answering
with `At`, and the reply checks), the preloaded `erx_file_remote` with
the client's last-name, error, file-information and offset rules
([design-files.md](design-files.md#erlang-clients-prim_file-and-erx_file_remote)),
both for the operations `/tmp` needs: `version`, `attach`, `walk`,
`lopen`, `lcreate`, `read`, `write`, `readdir`, `getattr`, `setattr`,
`mkdir`, `symlink`, `link`, `readlink`, `unlinkat`, `renameat`,
`statfs`, `fsync` (a no-op for `/tmp` that succeeds, as OTP's `sync` and
`datasync` cases need), `flush` and `clunk`, with the grammar generated
whole from its one table, so every other operation decodes and is
answered too: `auth` with `enotsup`, as every server answers it,
`remove` through `unlink` as `unlinkat` is, `mknod` with `eperm` and
`xattrwalk` and `xattrcreate` with `enotsup` from `/tmp`'s callbacks,
and `lock` and `getlock` with `enolck` until `erx_fs`'s locks arrive in
M4; the owner of an open file calling `read` itself for a module whose
`read_mode/0` answers `immediate`, as `/tmp`'s does, so M3 needs no read
helpers; and `/tmp` as the domain's
own `erx_fs` server ([design-tmp.md](design-tmp.md#where-tmp-runs));
the watchdog process, `erx_watchdog`, petting
from the system release; musl behind `liberx`; the console service and
the console's driver, an Erlang process in the system domain over the
device NIF, with no console NIF
([design-runtime.md](design-runtime.md#the-console-and-standard-io)), the
console's only input; `erx_console` copies raw bytes between that driver and
the group's terminal-less `prim_tty`, with `isprint/1` and `wcwidth/1` made
pure (edit 38), which is the system shell's permanent path: its tty stays raw
with every flag clear, so `erx_tty` is no part of it, and M3 needs neither
`erx_tty`, `erx_output`, a registered tty owner nor edit 35's trap, which come
with the first session's tty in Track S; logging stays OTP's default handler
over `user`, since only the system release's code runs here, and the log sink
and edit 43 come with the first other domain in M5; the console has several
writers, whose writes can
interleave: the console service, a runtime's descriptors 1 and 2 through
the seam's console write, and the kernel's log capability serving the root
before the driver runs and the crash handler after it, on
the UART that the system manifest names by its device-tree path, which
the device service checks against `/chosen/stdout-path` at boot, refusing
a manifest whose console differs
([design-system.md](design-system.md#devices)); the build behind
`tools/erx build runtime`; `prim_file`'s path resolution with its fuzz
target.

**Exit criteria.** The fast oracle subset passes in the system domain, and
OTP's `emulator`, `kernel`, `stdlib` and `compiler` suites run under stock
Common Test there and are compared case by case. Every case is the same as
stock, a bug fixed or in `TODO.md`, an explained difference, or "cannot run
in M3" with its reason (peer, spawn port, socket, C helper, load at run time,
file system) named and shown by the run. The counts are recorded and no
unexplained difference remains;
musl's `libc-test` runs in a test task that the root builds with every
failure a bug, a documented difference with a test, or an upstream bug
recorded as such; a deterministic-mode boot to the shell gives a
byte-identical transcript, under the recipe in
[design-stopgap.md](design-stopgap.md#deterministic-mode); the
manifest check fails the build on a seeded violation of each property in
its scope and on a seeded record outside that scope; a manifest whose
console differs from `/chosen/stdout-path` is refused at boot; the fuzz
targets of the Erlang manifest reader, of the file protocol's frame
grammar, which feeds both local messages and frames to `erx_fs`, and of
`/tmp`'s tree, its sequence test, run their budgets clean.

**Gate G3.** Measures: W1 of E-S1 (same-domain ping-pong and ring, spawn,
switch) against stock OTP 29.1.2 on the host; footprint; boot time to the
shell. Decides: the baseline every later change is measured against.
The first run, taken at a high load average and so not yet a valid
baseline, is
in [research-g3-baseline.md](research-g3-baseline.md); `tools/erx bench g3
--accel
hvf|tcg` measures it again.

## M4: The machine is an object

**Goal.** The live machine, which every later milestone is debugged with.

**Demo.** On the Mac, `erx watch` recompiles a changed module and hot-loads
it into the running system domain through the install facet; `erx:i()`
shows CPUs, threads, groups and processes with each value's reporter;
`erx:source(Pid)` shows the line a process is executing; `erx:trace` shows
ERTS scheduling and the backend's events (park, wake, interrupt delivery,
task start and end) on one timeline, the kernel's row unsupported until
erXos's kernel supplies its trace ring.

**Scope.** The generated inspection schema and its C/Erlang/Ruby bindings,
status/reporter-preserving renderers and `/proc` projections; generated
Ruby clients for host-exposed service operations, with their bounded
request/reply checks; the inspector, the tracer in the system domain
(its trace facet and relay come with M5's connections), the host link with its
sessions and deframer (and their fuzz targets), on the UART that the
system manifest
names by its device-tree path, the code service with the install arena
([design-live.md](design-live.md),
[design-runtime.md](design-runtime.md#code-in-the-system-domain)); the
code store in memory, with loads by hash, checked by the SHA-256
primitive ([design-runtime.md](design-runtime.md#per-byte-primitives)),
manifests, history and the missing-blob exchange
([design-live.md](design-live.md#the-code-store)); the system domain's
namespace, the
9P2000.L byte codec `erx_9p` built from the frame profile, with its fuzz
target, `erx_fs`'s locks, and the read helpers of servers that read from a
medium, with flush of helper work, and
`/proc` ([design-files.md](design-files.md)); the
host link's files stream, stream 4, which `tools/erx files` relays to a
UNIX socket on the Mac so that any 9P2000.L client there mounts the
machine's `proc` tree
([design-live.md](design-live.md#files-between-the-host-and-the-machine)),
while the host-tree domain, which serves the Mac's tree at `/host`, is
optional work of 1b-E ([M9](#m9-a-driver-is-an-erlang-process));
the line escape with its table generated from OTP's Unicode data, at each
display of labelled text, with a fuzz target
([design-live.md](design-live.md#attributed-text)); the `shell_default`
shortcuts and their collision test. The system domain runs the
interpreter image; BeamAsm comes with M5's ordinary domains. Basic
inspection also participates in the first integration checkpoint's full
boot with one application domain over its connection, before M5 is
complete.

**Exit criteria.** The host-link tests (session replacement, at-most-once
calls, credit, the 1,025th facet) pass; a module reloaded in a loop on four
CPUs never runs stale code; a blob one bit off its hash
never loads; every character class of the line escape has its test at each
display; `file:read_file("/proc/processes/0.N.S/status")` in the
system shell, `0.N.S` being a pid as `pid_to_list` writes it less its
brackets, returns every status the inspector can report; every value only
the kernel could report shows `unsupported` with its reporter, and budget
`used` shows `partial` with reporter `root pool`, each with a test; a
file read through `tools/erx files` equals its
source on the machine; the fuzz targets of the deframer, `erx_path`,
the 9P2000.L codec and each escaper run their budgets clean; the oracle's
suites meet M3's standard on the interpreter image in the system domain, with
the cases that need what M4 brings moved out of "cannot run".

## M5: A wall around some processes

**Goal.** The unified process space: many ERTS domains and native domains,
one pid space, one message system over connections, supervision across
domains, domains that end cleanly, each domain's own funnel deciding who
may signal its processes, and a system domain whose end is a reset.

**Demo.** From the system shell: create a domain, spawn into it with a
link, crash it, and receive `{domain_down, D, crash}`; inside a domain,
forge pids and see them behave as dead; kill a domain mid-burst and watch
its death arrive after its last messages and every charge return to its
principal's budget; watch a native test domain and an ERTS domain message
each other over a connection while they share four CPUs by grants; set a
hostile runtime on a neighbour's funnel for ten minutes and watch the
neighbour's latency hold while the flooder blocks on its own lane; and
kill the system domain under load, read the crash record on the console,
and watch the machine come back from the reset with nothing to reconcile.
On the stopgap (1b-A) the demo runs without the budget's return, the
grants and the hostile runtime, which M5's kernel part adds.

**Scope.**

* **The log sink**: `erx_log_h` as the `default` handler in every domain, the
  logger proxy, the console's escaped log lines, and edit 43 for
  `logger_simple_h`, before any other domain's text can reach a log
  ([design-live.md](design-live.md#the-console)).
* **Connections and lanes**: the lane's ring and reader page in the ABI
  file's layout, IRQ objects as doorbells, the wake handshake by published
  positions, and the system domain making a connection at a domain's
  creation and at each introduction
  ([design-domains.md](design-domains.md#connections)).
* **The funnel**, one C17 library in `liberx` linked by every runtime:
  `erx_lane_take`, which copies a frame out of the ring once, and
  `erx_funnel_check` over the domain's own export table, with safe
  decoding in the system domain and lazy decoding everywhere; the
  chokepoint check that only `erx_lane_take` reads a lane's pages
  ([design-domains.md](design-domains.md#the-funnel)).
* **The peer in ERTS**: every domain a node named `<id>@<host>` under
  stock distribution, `<D.N.S>` pids that print the domain id as the
  creation, one distribution entry per connection keyed by the peer's
  name as stock keys it, the `erx_connections` process of `erx` and the
  `erx_lane` linked-in driver as the carrier, the busy-port rule when a
  lane is full, the export table with its three writers (`erx:export/3`
  narrowing only), unguessable references, and the receive boost's
  plumbing (urgency in records); `erx_etf` in `liberx`
  ([design-runtime.md](design-runtime.md#connections-in-erts),
  [design-domains.md](design-domains.md#exports)).
* **Tracing across domains**: the trace facet and the trace relay in each
  traced domain, tracing of cross-domain frames, and trace records on the
  host link's events stream ([design-live.md](design-live.md#tracing)).
* **The domain library and the system services**: the domain library's
  full creation plan with undo, its fault thread and gate, end
  classification and `{domain_down, D, Info}`, connection down, whose
  objects are deleted once each party has unmapped them or ended and
  never on a timer while a party lives
  ([design-domains.md](design-domains.md#connections)), and the ordered
  end of the machine; the domain service, which creates the domains the
  system manifest configures and makes their
  introductions, domain pids, facets, code facets,
  `erx_domain:introduce/1,2`, with `erlang:disconnect_node/1` taking a
  connection down; namespaces
  built for every domain, with facets mounted as file servers, reached
  through `erx_file_remote` ([design-files.md](design-files.md)); identifiers
  checked by `erx_ident`
  ([design-system.md](design-system.md#identifiers)); domain ids
  allocated by the domain service, never reused within a boot
  ([design-system.md](design-system.md#the-domain-library),
  [design-system.md](design-system.md#creating-a-domain)); the system
  domain's runtime started with `ERX_BOOT_INSTALLED_ONLY`, so it loads
  only code from its release slice and its install arena
  ([design-runtime.md](design-runtime.md#code-in-the-system-domain));
  `/proc` with the previous boot's crash record under `[kernel, crash]`
  where the platform keeps one ([design-files.md](design-files.md)).
* **BeamAsm** in the BeamAsm image, the runtime image for ordinary
  domains, built beside the interpreter image, with JIT objects mapped
  twice in spaces allowed JIT objects, user-mode cache maintenance, the
  code barrier, libc++ without exceptions, and the repaired error paths
  ([design-runtime.md](design-runtime.md#beamasm)); the domain service
  starts BeamAsm domains, and the system domain runs the interpreter image
  and holds no JIT object.
* **The kernel interface sub-spaces and programs need**, on erXos's kernel
  with its conformance tests, as M5's kernel part: capability passing at a
  rendezvous and by
  `erx_cap_pass`, deleted memory whose mappings fault, `erx_mem_copy`, the
  emptying of a stopped space's table, space parents
  with stop propagation, sub-space creation by a domain allowed `SPACES`,
  and vCPU upcalls
  ([design-kernel.md](design-kernel.md#passing-capabilities),
  [design-kernel.md](design-kernel.md#closing-and-deleting),
  [design-kernel.md](design-kernel.md#creating-spaces),
  [design-kernel.md](design-kernel.md#vcpu-upcalls)), with the pass,
  deletion, stop and upcall cores explored on the host
  ([Track K](#track-k-erxoss-kernel)).
* **Tests**: the funnel's fuzz target and its differential test against
  `binary_to_term/1`; the fuzz targets of the lane reader, `erx_etf`, the
  system domain's safe decode and the facets' generated admission; the
  hostile-runtime suite at the receiving funnel of
  [design-domains.md](design-domains.md#verification-and-testing); the
  root task's end tests of
  [design-system.md](design-system.md#verification-and-testing).

**On the stopgap (1b-A).** Every bullet of the scope lands on the stopgap
Fiasco except two: tracing across domains, which lands in 1b-C, whose
browser views are its first consumer
([track D](#track-d-windows-widgets-and-the-web)), and the kernel
interface sub-spaces and programs need, which
lands on erXos's kernel as M5's kernel part, after M2. On the stopgap its
consumers use rows that the Fiasco backend adds behind the unchanged
interface, the creations and passes among them called from the root,
where the domain library runs, and
the hosted backend, one process through 1b-A, adds only
where they are cheap ([track H](#track-h-hosted-mode)): a memory object mapped into
another task, its destruction revoking it in every task that mapped it;
spaces created by the root, each with its budget, fault gate and label
recorded, and an exit record with the exit status or a crash; IRQ objects
created by the root and bound once to a group, whose deliveries reach the
dispatcher of the group's home task, triggered and acked by any holder;
`erx_cap_pass` from the root's table into a space it created, item by
item until the first refusal; tables
that grow from the root's pool, with each task's handle table sized by
the `cap_limit` its creator gives; groups and budgets as records with
nothing enforced or counted, a budget's destroy deleting everything
charged to it; and release slices, `erx_image_map` and `erx_mem_copy`
through the root service
([design-stopgap.md](design-stopgap.md#the-call-table)). Sub-spaces
created at a task's request and ended with their parent, creation and
passing from a task other than the root, and paged objects, sealing,
supply and `ERX_MEM_CODE` come with 1b-B, whose sessions are their first
consumer ([track S](#track-s-the-command-shell-and-toybox)); device
objects given to a holder domain come with 1b-E
([M9](#m9-a-driver-is-an-erlang-process)); whether vCPU upcalls get a
row is settled before 1b-D ([track P](#track-p-the-posix-lite-personality)).
Passing at a
rendezvous, pauses, IPC gates above `liberx` and every budget and grant
enforcement stay refused, each a recorded residual. The funnel's verdicts
run unchanged in user mode; what the stopgap cannot promise is that a
domain which bypasses `liberx` is stopped by anything
([design-domains.md](design-domains.md#on-the-stopgap)).
BeamAsm lands beside 1b-A, off its critical path, since it needs nothing
of the kernel. The hostile suites' verdict cases are written in 1b-A;
their bound and confinement cases and the budget criteria are written at
M5's kernel part. On the stopgap the verdict cases, whose verdict is
user-mode code's answer to what it reads, a funnel's to a malformed or
forged frame, run and count; the cases that check a bound on memory, CPU
or a neighbour's latency, the budget criteria and every case against a
domain that bypasses `liberx` run on erXos's kernel alone
([design-stopgap.md](design-stopgap.md#what-phase-1-code-must-not-assume)).

**Exit criteria, on the stopgap (1b-A).** The two-node differential
scenario suite passes, every difference in the compatibility table; the
oracle's suites meet M3's standard on the BeamAsm image in an ordinary
domain that the domain service starts, with the cases that need a peer
moved out of "cannot run"; a module reloaded in a loop on four CPUs under
BeamAsm never runs stale code; no mapping is writable and executable
together, and a BeamAsm domain's JIT object faults on an execute through
its RW alias and on a write through its RX alias; the interpreter image
links no BeamAsm, asmjit or libc++ symbol; the invariants of
[design-domains.md](design-domains.md#invariants) that hold in user mode
have their tests, green here, and those that rest on the kernel get
theirs at M5's kernel part; the exhaustive models of one lane, of one
connection whose peer ends and of cross-domain links among three domains
pass, progress included; the soak of a million cross-domain calls from
short-lived processes and from a long-lived one whose calls time out
passes with the callee's export table at its live correspondents; the
wake handshakes' litmus tests pass under herd7, with and without their
fences, and the lane's reader under TSan with a writer rewriting its
pages; a malformed frame ends the connection from the receiver's side and
the peer sees `noconnection` on everything across it, in order with what
the target sent before (D9); the system domain killed under load, an ERTS
fatal error in the system domain, `erlang:halt/1` from a system process
and a stopped watchdog pet each leave a crash record on the console naming
its cause and the machine ended as `erx.panic` says;
a peer that ignores `connection_down` leaves its connection closing,
counted against its own `connections` quota, with the inspector showing
it as closing and nothing else changed; F1, F2 and F5 have their tests on
the file servers' side, a grant derived
on a subtree reaching nothing above it whatever its client sends;
budgets, grants and every charge, but the root's budget's `used`, read
`unsupported` in the inspector, never a fabricated value;
`file:read_file("/proc/processes/4.N.S/status")` in the system shell,
where 4 is the system domain's id, returns every status the inspector can
report.

**Exit criteria, on erXos's kernel (M5's kernel part).** Every criterion
of the stopgap's list passes again, by M7's parity; the kernel interface
of the scope passes its conformance tests; the hostile runtimes run ten
minutes without affecting their neighbours' memory, messages and
liveness, each flooder blocking on its own lane and the system domain on
its own grant; a domain killed mid-burst gives every charge back to its
principal's budget; F1, F2 and F5 hold on the kernel's side; K21, K25 and K26
hold across domains, every capability to a deleted object invalid at
once, with K26's container test, a map racing the destroy of its space,
passing, a deleted memory object faulting in every space that mapped it,
a peer that answers `connection_unmapped` but keeps its mappings
faulting on its next access, in its own domain and nowhere else, and no
server or driver ever mapping memory a client can
delete; a domain's sub-spaces stop with it and report their ends before
it (K27); the vCPU conformance tests pass, interrupting a worker that
computes, one that waits on a umtx word and one that waits for a reply,
and checking that a message to an armed thread with events enabled enters
no upcall and that a resume over a cleared pending flag still takes the
queued event.

**Gate G5, provisionally at 1b-A and confirmed on erXos's kernel.** At
1b-A, on the stopgap, it measures what is user-mode cost: E-D1 and E-D2,
with `tools/erx bench xdomain-pingpong` and `xdomain-throughput`, and, in
an ordinary domain, BeamAsm's speedup over the interpreter on OTP's
benchmarks and on the oracle's suites, the footprint of a domain in each
flavour and the time to translate a release when the domain starts. It
decides provisionally: the default table sizes of the runtimes and the
domain service, a domain's `cap_limit` among them, and not the
stopgap's own fixed limits; the defaults of `lane` and
the manifest's `system_lane`, the producer's wait rule and whether ERTS
encodes straight into the lane; the funnel's allowance per step; the busy
limit and the facets' `max_request` and heap limits
([design-domains.md](design-domains.md#performance)); and whether a
trigger of the ahead-of-time roster fires
([design-runtime.md](design-runtime.md#running-erlang-code-the-options)).
BeamAsm's part is measured with `tools/erx bench g5`, in
[research-g5-beamasm.md](research-g5-beamasm.md).
At GK3, on erXos's kernel, it measures E-D3 and E-D4, with
`tools/erx bench xdomain-stall` and `domain-lifecycle`, and the full form
of E-S2 with ERTS processes in one domain and in two domains over a
connection against kernel threads in one and two spaces, repeats the
stopgap's measurements, and decides the death path's batching and the
manifest's `system_queue`, confirms or revises every provisional decision,
and confirms or overturns the absence of any kernel object per
lightweight process.

## Track S: The command shell and toybox

The release command catalog is generated from module metadata and the
image's program list: names, help and required facets, with callback
and live-load publication checks
([Generation work](#generation-work)).

**Goal.** A command shell with rc's language in every session, and UNIX
commands from toybox as ports of the session, sharing one command
namespace with Erlang commands ([design-shell.md](design-shell.md),
[design-programs.md](design-programs.md)).

**Demo.** In a console session, `ps -o pid,rss,comm | sort -rn -k2 |
grep erx` prints FreeBSD's text, `-` for each value erXos does not
measure, as FreeBSD's `ps`, `sort` and `grep` would;
`find /tmp/logs -type f | xargs tail -n 1` runs toybox applets in
sub-spaces of the session over a pipe, and `ps` lists them under the
session as its process table; `within /tmp/logs -- find /tmp/logs`
reaches nothing else; `Ctrl-Z`, `bg`, `fg` and `kill %1` move and end a job of
Erlang commands, and of programs once M7 has brought erXos's kernel's
pauses.

**Scope.** The shell is Phase 1's, after M4, and runs there in the system
domain with its authority, as the system shell does; the session domain,
programs and executables from EROFS through sealed file objects follow
1b-A, on the stopgap, as 1b-B, whose first slice is the session domain;
the sub-space port of littlefs follows in 1b-E, where the storage domain
first holds the block device; the job control of programs follows
M7, on erXos's kernel. On the stopgap a program's budget and group are
unenforced records, its doorbells are IRQ objects whose deliveries reach
the dispatcher of the task that consumes them, the program's for its own,
and the pipe server's and the session's creates and installs
are requests to the backend's root service. The backend gains here the
rows a session is the first to call: sub-spaces created at a task's
request, each with its parent recorded and ended when its parent ends;
spaces, IRQ objects, passes and image maps asked for by a task other than
the root; and paged objects, sealing, supply and `ERX_MEM_CODE` for the
code objects the domain service makes
([design-stopgap.md](design-stopgap.md#the-call-table)). The narrowing of `within` is
the handler's table and the servers' grants, user mode, and holds there,
while that a program cannot escape `liberx` does not
([design-programs.md](design-programs.md#a-program-is-a-port)):

* the shell in Erlang: tokenizer, parser, evaluator, the interactive
  layer on `edlin`, job control, `erx_cmd` and the first Erlang commands,
  and the parser's fuzz target; plan9port's rc built from its pinned
  source as the oracle, with the corpus from `test.rc`, the parser checks
  and `trip.rc`;
* the session domain, which the domain service starts for a console
  line's login and the host link's, in a development build `root`'s, with
  the shell and its command server in it; the principals, quotas and
  logins of other principals follow in M10
  ([design-domains.md](design-domains.md#principals-sessions-and-quotas));
* programs as ports of the session, over the sub-spaces 1b-B brings: the
  port driver `erx_program`, which carves the program's budget from the
  session's, creates a child group of the session's programs group, the
  anchor space (its parent is the starter's anchor, or the session's own
  space) and the image space below the anchor, maps the image through
  `liberx`'s loader, creates the channel, installs the pipe ends and the
  startup message and starts the first thread
  ([design-runtime.md](design-runtime.md#programs-as-ports),
  [design-programs.md](design-programs.md#a-program-is-a-port)); the
  command server and a handler per program, which serves every request on
  the channel with the session's authority after checking the program's
  own table, relays file requests over the session's connection and moves
  file bytes through the data area the session supplies
  ([design-programs.md](design-programs.md#the-handler)); the channel
  protocol and the startup message with their fuzz targets; `derive` in
  `erx_fs` and the session's export; the descriptor table over pipe ends
  and grants; the spawn planner, spawn and wait; the session's terminal
  relay, which owns its tty, with the line discipline `erx_tty`, its
  exhaustive model and its fuzz target
  ([design-live.md](design-live.md#the-tty)); `erx_output`, the registered
  tty owner and the normal halt's drain, with edits 35's trap and 42, in place
  of the seam's console write for a process's output
  ([design-runtime.md](design-runtime.md#the-console-and-standard-io));
  the session's pipe server, `erx_pipe_srv`, which makes every ring
  and every doorbell and installs every end, with the exploration of its
  pipe core, and the pipe NIF ([design-pipes.md](design-pipes.md));
  executables run from the EROFS
  images through the sealed file objects a program's session maps
  ([design-programs.md](design-programs.md#what-a-program-can-start));
* the job control of programs through `erx_space_pause` and
  `erx_space_resume` on the program's image space, the pauses coming from
  track K's after-the-switch increment;
* toybox 0.8.15 and `wak` imported as erXos's code and built applet by
  applet, each with toybox's own tests in a test domain.

**Exit criteria, the shell (Phase 1).** The shell's corpus agrees with
plan9port's rc, every difference classified and pinned by a test; job
control pauses, resumes and ends jobs of Erlang commands three generations
deep; the parser and `grep`'s pattern translator run their fuzz budgets
clean; `ps`, `ls`, `grep`, `sort` and `wc` agree with FreeBSD 15.1's over
their corpus in the oracle guest, every difference classified and pinned
by a test.

**Exit criteria, programs (1b-B).** Toybox's tests pass for every
applet built, or each failure is classified; a pipe's end of stream
arrives only after its last writer goes and every byte written has been
read, a writer that faults included, and a program's end reaches its
port's owner as `{exit_status, N}` after its last bytes; a domain's
sub-spaces, a session's programs among them, end with it; a pipe with a
paused reader and sixty-four writers still spawns its sixty-fifth, which
blocks on its write, never on its spawn; job control pauses, resumes and
ends jobs of programs, checked at M7, which brings the pauses; all 256
byte values and every control sequence a program writes reach the
console exact (V1); a narrowed program that tries every command name
reaches nothing outside its grants, and a program holds no grant's pid
and reaches nothing but its channel and the memory its session mapped
(SH1 of [design-shell.md](design-shell.md#invariants), P2 of
[design-programs.md](design-programs.md#invariants)), checked through
`liberx` on the stopgap and, against a program that bypasses `liberx`,
with its budget and grant enforced, at M7; passed files share their
offsets; the startup message and the channel protocol run their fuzz budgets
clean.

**Gate G6 baseline, at the end of 1b-D.** Records, on the stopgap, under
HVF and TCG apart, the memory of an idle domain of each kind, an ERTS
domain and a native test domain, of a session with its shell and of one
program as a sub-space, what the session's own services use, and a
facet's heap; E-D1's round trips and E-D2's draining under many
connections; and `tools/erx bench fs` from a program and from an Erlang
process and `tools/erx bench blk`, against M6's baseline. It decides
nothing: the stopgap enforces no budget, so a budget settled on its
numbers would be settled on what it does not enforce.

**Gate G6, after M5's and M9's kernel parts.** Measures the system on
erXos's kernel, under HVF and TCG apart: the memory of an
idle domain of each kind, an ERTS domain and a native test domain, of a
session with its shell and of one program as a sub-space, with what the
session's own services use against the sixteenth of its budget they keep
([design-system.md](design-system.md#resource-policy)), and a facet's heap
against its limit; the cost of a frame across a connection, E-D1's round
trips and E-D2's draining under many connections, and the system domain's
peak memory per domain with the host link's session at its resident limit
([design-domains.md](design-domains.md#performance),
[design-live.md](design-live.md#the-host-link)); a program's start
against GP's budget; isolation, the latency and throughput a well-behaved
domain keeps while a hostile domain floods it, spins, exhausts its budget
or crashes beside it, with the hostile-runtime and hostile-program suites
under load, the system domain on its own grant; and the throughput and
commit latency of the EROFS reader, of littlefs and of the block driver
on QEMU, with `tools/erx bench fs` from a program and from an Erlang
process and `tools/erx bench blk`, against M6's baseline and the G6
baseline. Decides whether
the system meets the design's budgets, among them a minimal ERTS domain of
about 10 MB and, under HVF, a round trip of 3 us with executors busy and
10 us with them parked, and confirms or revises G5's lane defaults and the
facets' limits; where a number misses its budget, the design returns to the
user with the numbers before M8 and M10 build on it.

## Track P: The POSIX-lite personality

**Goal.** UNIX programs recompiled without porting
([design-programs.md](design-programs.md#the-posix-lite-personality)).

**Demo.** A UNIX program recompiled unchanged against erXos's musl runs
from the shell: it creates pipes, waits on them with `poll`, spawns
children with `posix_spawn`, runs an `rc` command with `system`, and
handles `SIGINT` from the terminal; a program compiled into a tree the
session may write runs through the same tree's `rx` grant.

**Scope.** Generated contextual error translations and fault/signal
mappings, checked against musl/OTP and the protocol oracles, with no
unmapped exposed status ([Generation work](#generation-work)); descriptors
with `dup` and `fcntl`, `pipe`, `poll` and `select`,
`posix_spawn` with inherited descriptors and file actions, `wait` and
`kill`, process ids from the session's process table, `getuid` and the
synthesised `/etc/passwd`, `mmap`, `alarm`; `liberx`'s pipes over the
rings and doorbells the session's pipe server makes and maps, with their
exhaustive model and fuzz targets on the host
([design-pipes.md](design-pipes.md#making-a-pipe)); `liberx`'s signals
over the vCPU upcalls of the stopgap's vCPU row or of M7, triggered by the
session's port driver
([design-programs.md](design-programs.md#signals-in-liberx)), with
`erx_sig_step` explored on the host; the generated `errno`, signal and fault
tables; `erx_exec` and `erx_elf_plan` with its fuzz target, and `rx` grants
with the `exec` open; `rc` in program mode, and `system` and `popen` over
it; the Open POSIX Test Suite as an external test tool in a test domain.
Its first part, descriptors with `dup` and `fcntl`, `pipe`, `posix_spawn`
with inherited descriptors and file actions, `wait` and `kill`, and
`erx_exec` with `rx` grants, is 1b-D: it follows track S's programs, on
the stopgap, and ends with the G6 baseline. The rest follows. Signals
depend on a source check of Fiasco's vCPU interface in the kernel-mode
build, made before 1b-D starts
([design-stopgap.md](design-stopgap.md#open-decisions)): if it carries the ABI's `erx_vcpu` layout without leaking
Fiasco's, the backend gains a vCPU row and `kill` and catchable signals
run on the stopgap; otherwise the stopgap delivers only signals whose
default action ends the program, and catchable signals arrive at M7.

**Exit criteria, the first part (1b-D).** Descriptors, `dup`, `fcntl`,
`pipe`, `posix_spawn` with inherited descriptors and file actions, `wait`
and `kill` pass their cases of `libc-test` and the Open POSIX Test Suite,
every other failure among them classified; without the stopgap's vCPU
row, a case that needs a signal handler shows as "cannot run" with that
reason and runs at M7, and `sigaction` with a handler fails with
`EINVAL`; with the row, the vCPU conformance tests of M5's kernel part
pass on the stopgap; a pipe's bytes stay readable
after their writer ends; a crash of the session's pipe server makes reads
fail with `EIO` and writes with `EPIPE`, never a false end of stream; an
executable runs through an `rx` grant and is refused through `ro` and
`rw` ones; `erx_elf_plan` and the startup message's decoders run their
fuzz budgets clean.

**Exit criteria, the track.** musl's `libc-test` and the Open POSIX Test
Suite pass,
every case that needs `fork` or a facility the personality lacks recorded
as unsupported and every other failure classified; a signal sent while the
main thread computes, runs inside `liberx`, waits on a umtx word, waits
for a reply, is in a call on its channel or is about to sleep is
delivered each time, the call's case once the call returns, and its
handler's return restores the thread exactly; a pipe's bytes stay readable
after their writer ends; a crash of the session's pipe server makes reads
fail with `EIO` and writes with `EPIPE`, never a false end of stream; a
file write interrupted by a handler returns its count; `poll` over 500
pipe ends reports exactly the ready ones; an executable runs through an
`rx` grant and is refused through `ro` and `rw` ones; `system` and
`popen` return the wait statuses of `rc`'s `$status`; `erx_elf_plan` and
the startup message's decoders run their fuzz budgets clean.

**Gate GP.** Measures a program's start from the session's `spawn` to its
`main` with `tools/erx bench spawn`, against the budget of
[design-programs.md](design-programs.md#performance) and against
`posix_spawn` on Linux in a guest, and the `make`-shaped workload of
[Simplification experiments](#simplification-experiments), first in
hosted mode and then under HVF, where its numbers on the stopgap are
provisional. Decides the channel's and the data area's defaults, the
handler's batching and whether the pipe server keeps one ring per write
end. Whether a program's start needs a cheaper path than one kernel call
per object is decided at GK3 on erXos's kernel, since on the stopgap each
object is one request to the backend's root service.

## Track D: Windows, widgets and the web

**Goal.** A browser, a kiosk and a desktop on QEMU `virt`, and a panel
on a board, as displays of the running system: one widget interface on
all of them, terminals as programs of the user's session, and typed
values as presentations
([design-display.md](design-display.md), [design-web.md](design-web.md)).

**Demo.** On the Mac, `tools/erx web` shows in a browser the inspector's
records, `/proc`, the kernel log and a trace of a QEMU guest that has no
network and no display device, every typed value a link; an Erlang
application opens the same user interface term on the `web` display and
on a QEMU `virt` kiosk, which boots into that one full-screen application
drawn by LVGL; a desktop follows, where a terminal window runs the shell
with job control and a click on a pid that `ps` printed in that terminal
inserts it into the command line; a Raspberry Pi 4 kiosk boots into one
full-screen application, takes touch input and turns its panel off when
idle.

**Scope.** Eight parts, each ending in its own exit criteria. The first
slice needs no device: a browser on the developer's host over the host
link, which every QEMU guest already has. The kiosk comes before the
desktop, since a kiosk under LVGL needs none of the desktop's draw stack
([design-display.md](design-display.md#kiosks-and-glasses)). The pure
cores the parts use build for the host and are written and tested there,
with their fuzz targets, ahead of the part that integrates them
([design-display.md](design-display.md#verification-and-testing)).

For the web and the kiosk:

* the widget tree's validator `erx_ui_schema`, over `abi/formats/ui.txt`,
  and `erx_ui_model`'s numbering, difference and event check;
* `erx_present`'s canonical texts over the inspection schema's `present`
  marks;
* `abi/protocols/web.txt` with its generated Erlang and TypeScript codecs;
* the generated C reader of `ui.txt`'s binary form, and `erx-lvgl` built
  for the host against a model screen that plays the screen owner over
  its two pipes.

For the desktop:

* the draw protocol's state machine `erx_draw_core` and its generated
  decoder `erx_draw_codec`, with a C decoder of the same messages;
* `erx_memdraw`, the pixel primitives of 9front's `libmemdraw`, checked
  against `erx_draw_ref`, a slow Erlang reference for compositing, and
  against 9front's unmodified `libmemdraw` built for the host for every
  operation, shapes included; and `erx_draw_image`, the Erlang decoder of
  image(6)'s compressed pixels (the `Y` decoder), whose oracle is the
  same 9front build's loader;
* the screen's composition `erx_screen_core` and the two window policies
  `erx_wm_rio` and `erx_wm_single`;
* the terminal's state machine `erx_vt`.

In this track W1 to W8 name design-web's invariants and G1 to G8
design-display's, not the plan's gates or E-S1's workloads. Parts that
land after M11 repeat M11's closure over what they add.

1. **The web over the host link**, as 1b-C, after 1b-A, which brings the
   domain service, and the session domain, 1b-B's first slice, which
   brings `root`'s session domain, the session a browser's views run in;
   nothing in it needs the kernel. The web domain, a configured
   domain of the development manifest,
   with the connection core `erx_web_conn`; the session's `erx_web_line`,
   whose views fetch records, the kernel log and traces through the
   session's own inspect and trace facets, with M5's tracing across
   domains, the trace facet and the trace relay, which land here
   ([M5](#m5-a-wall-around-some-processes)); the host link's `web` facet,
   bound to `root`'s session, with the manifest check's refusal of it in a
   release manifest; `tools/erx web` with its loopback server, token,
   cookie and `Origin` checks and its WebSocket relay; the client under
   `web/`, built by `make web` offline from the store `tools/erx fetch`
   fills, with the generated escape, `MachineText`, `hrefOf` and the
   content security policy; the client's chokepoint checks, and the ASCII
   check over its `.ts` and `.tsx` sources
   ([design-web.md](design-web.md#the-host-tools-front-end)).
2. **Widgets on the web**, in 1b-C, after part 1. The display service of
   `abi/services/display.txt` and its generated dispatch; `erx_ui`, which
   opens a user interface on the display its options name or on the
   session's `display` variable; display facets, minted when the system
   domain introduces a session to a display, the web's display facet
   named `web`; `erx_ui_server` with the browser renderer; the readers of
   `ui.txt`'s binary form in Erlang and TypeScript
   ([design-web.md](design-web.md#uis-the-browser-renderer),
   [design-display.md](design-display.md#choosing-a-display)).
3. **A kiosk on QEMU `virt`**, in 1b-C, after part 2, 1b-E, in which
   a configured domain other than the system domain is given its devices
   at its creation, and 1b-B's sub-space ports, which run the LVGL program. The
   devices attach over virtio-mmio on the stopgap, unconfined, and over
   virtio-pci behind the IOMMU from M9's kernel part; the drivers' move is
   a device record and a DMA profile, not driver code. The display domain
   in its kiosk form: the virtio-gpu and virtio-input drivers in Erlang
   over the device NIF, with the driver's `flush` of rectangles and their
   pixels; the screen owner `erx_ui_kiosk`, which admits the one UI of the
   application the manifest names and answers any other open `{error,
   busy}`; `erx_ui_lvgl` with the screen target, and `erx-lvgl`, LVGL as
   a native program in a sub-space of the display domain behind
   `erx_ui_renderer`, with the generated C reader of `ui.txt`'s binary
   form, its `pixels` reports and its `screen`, `input` and `repaint`
   records; the kiosk's manifest entry, whose application is a configured
   domain holding a display facet, with no login; the manifest check's
   refusal of an unconfined DMA device in the display domain of a release
   manifest, while the Phase 1 manifest check allows one in a development
   build. On the stopgap a compromise of the display domain's Erlang
   reaches the GPU's DMA, a recorded residual; the LVGL program holds only
   its pipes ([design-display.md](design-display.md#kiosks-and-glasses)).
4. **Kiosks on boards**, after part 3 and M12's boards. The firmware
   framebuffer driver of the Raspberry Pi; a panel on a serial bus;
   touch, encoder and keypad drivers, and the `events` operation for an
   input device in another domain, such as the devices domain; the screen
   owner's idle policy, with the panel off when idle; the reserved chord,
   which reaches no renderer; Gate GD on the panel, once part 6's
   Erlang renderer runs
   ([design-display.md](design-display.md#kiosks-and-glasses)).
5. **A desktop on QEMU `virt`**, as 1b-F, after 1b-E and part 2. On the
   stopgap a hostile draw client that corrupts the display domain reaches
   the GPU's DMA, a recorded residual
   ([design-display.md](design-display.md), the display domain's trust).
   The display domain with `erx_winfs`, one `erx_window` per
   window, `erx_screen` and the overlapping policy with its menu; the
   driver's `flush` from an `erx_memdraw` image; the session's grant on
   the window tree and the handler's binding of one window's directory
   into a program's namespace; `/snarf`; the terminal `erx_term` in the
   session's release, the master of a tty of the session's terminal
   relay, with its sibling windows; the display's session, which the
   manifest's display entry names and the domain service starts at boot
   with no login; the reserved chord; the inspector's windows under
   `[domains, Id]` and `/proc`
   ([design-display.md](design-display.md#windows-and-the-window-system),
   [design-display.md](design-display.md#the-terminal),
   [design-display.md](design-display.md#a-displays-session)).
6. **Widgets and presentations on the desktop**, in 1b-F, after part 5.
   A widget server per window in the display domain with the Erlang
   renderer, glyphs from plan9port's `fixed` fonts, and the LVGL renderer
   in a window, its reports loaded with `y` messages; the single policy,
   for a kiosk under the Erlang renderer; presentations at a terminal:
   `erx_render`'s links at a tty that declares `links`, the link parser in
   `erx_vt`, and the input context from the command catalog's
   `-erx_args`; the Erlang renderer's QEMU frame time as Gate GD's
   preview, deciding nothing
   ([design-display.md](design-display.md#presentations)).
7. **Plan 9's programs**, in 1b-F, after part 5 and track P's first part
   (1b-D); 9term
   and acme's `win` after track Q's pseudo-terminals. plan9port's
   `libdraw` with Plan 9's file connection in place of `devdraw`'s pipe,
   and acme, sam and 9term, imported as erXos's code with an origin file
   ([design-display.md](design-display.md#compatibility-and-migration)).
8. **The web on the network**, after part 2, M10's logins, M11's vault
   and 1b-G's network service with TLS. cowboy over TLS in the web domain;
   `erx_web_login`, its cookies and a session per login; the manifest
   check's refusal of plain HTTP in a release build
   ([design-web.md](design-web.md#the-network-front-end)).

**Exit criteria, the web over the host link.** Random messages of every
kind round-trip between the Erlang and the TypeScript codecs, both
carrying one hash, and a client of another build is refused at `hello`;
the fuzz targets of `erx_web_proto`, the TypeScript decoder, the escape and
the host tool's HTTP and WebSocket reader run their budgets clean; the
client's `/proc` and `erx:` encoders and its presentation path table agree
with `erx_procfs`'s and `erx_present`'s over the generated corpus; the
attributed-text corpus renders in Chromium as text, with no element
created, `tsc --noEmit` fails on a seeded component that renders a
`MachineText`, and the content security policy blocks a seeded inline
script and a seeded `eval` (W2, W3); each of W4's refusals holds against
its seeded server; every URL form, and a reconnect with a trace page
open, starts no trace (W6); `unknown`, `timeout` and `partial` values show
their tokens, a stopped guest marks every view stale, and a log ring's
overrun shows a gap with its count (W7); the seventeenth view, the
sixty-fifth line view and the fifth connection of a line are each
refused, a client that never sends `next` gets one update per view while
the web domain holds under 1 MiB for it, and a record that changed 100
times while the client paused arrives once (W8); every view through the
host link's `web` facet equals what `root`'s session reads through its
own facets (design-web's W1 over the host link); a release manifest that
lists the host link's `web` facet fails the manifest check; `make web`
twice with the network disabled gives byte-identical files; each
chokepoint check catches its seeded violation; the end-to-end tests run
`tools/erx web` against a QEMU guest under HVF.

**Exit criteria, widgets on the web.** A user interface attached,
detached, changed and re-attached shows the newest tree,
`apply(delta(A, B), A) == B` over random trees, and a tree whose
difference exceeds one update arrives over several and applies at
`commit`; `erx_ui:open/1` with no display facet answers `{error,
no_display}` at once and opens on the display its options name, a stopped
web domain sends each opener `{ui_down, Window, display_down}`, and
closing every browser ends no user interface; scrolling, focus and
selection in the browser send nothing to the machine; a `secret` input's
text appears in no counter, log, trace or crash report; the `ui.txt`
readers' fuzz targets run their budgets clean.

**Exit criteria, a kiosk on QEMU `virt`.** The parity test runs one
corpus of trees and input sequences through LVGL and the browser
renderer and finds the same events, values and nodes; the fuzz targets
of the C reader, of the Erlang reader of the program's records, the
`pixels` record among them, and of the virtio-gpu response and
virtio-input event parsers run their budgets clean; a `pixels` rectangle
outside the screen, or with one byte too few or too many, is refused and
the driver never called; a second `erx_ui:open/1`, from the named
application or another domain, answers `{error, busy}`; a driver restart
is followed by one repaint of the whole screen; an idle kiosk makes no
device request for a minute (G6); the framebuffer copy under UBSan at its
bounds; a screenshot through QEMU's monitor equals the reference image
under HVF; the kiosk's manifest boots into the application it names with
no login; a release manifest that gives the display domain an unconfined
DMA device fails the manifest check (design-display's confinement test),
while a development build's manifest with the stopgap's virtio-mmio
devices passes the Phase 1 manifest check; each chokepoint check catches
its seeded violation.

**Exit criteria, kiosks on boards.** The fuzz targets of the touch,
keypad and encoder parsers and the `events` validator run their budgets
clean; a panel driver passes against a model of its command set on the
host; the reserved chord reaches no renderer; the panel turns `dim` and
`off` after the idle times and on at the next input; G6's idle test at
the driver; a Raspberry Pi 4 kiosk boots into the application its
manifest names.

**Exit criteria, the desktop.** `erx_draw_core` explored exhaustively,
where a seeded skip of the quota check fails; the draw decoder's fuzz
target and its differential test against the C decoder; `erx_memdraw`
agrees pixel for pixel with `erx_draw_ref` over random compositing
operations and with the 9front build over every operation, shapes
included, also
under ASan and UBSan with rectangles far outside every image; the `Y`
decoder's fuzz target; `erx_screen_core` explored exhaustively, and G2's
hosted runs under TSan and ASan; a seventeenth dirty rectangle yields one
bounding box and a `mouse` queue past 4 KiB drops its oldest record; G1's
tests across connections, sessions and a narrowed program; a window's end
frees its images, measured by the domain's budget; the `wctl` grammar's
fuzz target; the policies' property tests; `erx_vt` explored, fuzzed and
compared with a host terminal emulator's screen over a corpus that
includes `vttest`'s core; V1's byte test of design-live with `erx_term`
in place of the serial line; screenshots through QEMU's monitor equal the reference
images under HVF; a fault injected for each row of
design-display's failure table has that row's effect and recovery and
loses only what the failing party owned (requirement 10 and the
failures test of
[design-display.md](design-display.md#verification-and-testing)); a
display's configured session gets
its terminal's window at boot, and a new one when its last window
closes, where a seeded domain service that skips the introduction fails;
with the display running, the console's lines are the UART and the host
link alone and the display domain holds no facet of the console service;
the reserved chord, typed while each window has the keyboard, reaches no
window; `erx:attach` of `root`'s UART session from a terminal on the
display gives that session without the system-shell facet;
each chokepoint check catches its seeded
violation.

**Exit criteria, widgets and presentations on the desktop.** The parity
test runs one corpus of trees and input sequences through the Erlang and
the browser renderers and finds the same events, values and nodes;
`parse(Type, text(Type, Value)) == Value` for every type of the schema;
links appear only at a tty that declares `links`; the link parser's fuzz
target runs its budget clean; the input context highlights exactly the
types the catalog declares for the command typed; G4's `no_facet` test,
where a seeded facet call in the emulator is caught by the source check;
G7's status tests through a widget tree; `erx_ui_schema`'s fuzz target
over trees from another domain, with a tree carrying more fresh atoms than
`foreign_atoms` dropped and counted; the single policy shows at most one
window and delivers the reserved chord to no window.

**Exit criteria, Plan 9's programs.** acme and sam open, edit and save a
file in their windows under HVF, and 9term runs the command shell
over a pseudo-terminal; the display domain refuses no draw message they
send.

**Exit criteria, the web on the network.** Two principals logged in
through cowboy each see their own `/proc` snapshots and `ended scope` for
the other's domains (W1); one scripted client through the host tool and
through cowboy receives byte-identical messages (W5); a logout ends only
its own session; the seventeenth login is refused; a release manifest that
allows plain HTTP fails the manifest check.

**Gate GW, with part 1.** Measures a record view's round trip over the
host tool's front end, for the machine's record and a 1,000-child listing,
under HVF and over a 115,200-baud UART host link. Decides whether
whole records stay on the wire or the protocol gains a record difference
([design-web.md](design-web.md#risks-and-open-questions)).

**Gate GD, on part 4's panel, once part 6's Erlang renderer runs.**
Measures the Erlang renderer's difference, layout and drawing time per frame on a 240
by 240 panel
against LVGL's, on the same panel, with the parity test passing through
both. Decides whether LVGL leaves the panels; while it does not, LVGL
stays behind the renderer behaviour and the gate is measured again as the
Erlang renderer improves
([design-display.md](design-display.md#risks-and-open-questions)).

## M6: Immutable code, lasting data

**Goal.** The system's files come from immutable images read through one
block-checking funnel, and one practical store keeps data across power
cuts, so the system is one a person can use. The funnel passes blocks
through unchecked until M11 adds the hash check.

**Demo.** A QEMU disk image holds a slot with the release's EROFS images
and a data partition. Booted from it, the shell reads the release's files
from the slot's EROFS image; a file written and synced under `/data` survives
the guest's power cut and the next boot.

**Scope.**

* **A block device.** The virtio-mmio block driver, an Erlang process
  under a supervisor in the system domain, over the device NIF
  `erx_device` in its first form, on which M3's console driver already
  runs: register reads and writes by name through the generated
  accessors, a buffer pool in a DMA-mapped memory object, descriptors
  posted and completed, and the line's IRQ object bound to the system
  domain's group and delivered to the driver process as a process sink
  ([design-runtime.md](design-runtime.md#the-device-nif),
  [design-system.md](design-system.md#drivers)); the driver parses the
  device's descriptors in Erlang; ordinary interrupts and unconfined DMA,
  the stopgap's driver profile, which M9's kernel part replaces with
  virtio-pci behind
  the IOMMU and M11 refuses unless configured; partition windows in the
  block service, with the partition table, its two extended boot records
  included, and its fuzz target
  ([design-storage.md](design-storage.md#data-model)).
* **Immutable code and files.** The block client, a local call in the
  system domain, `erx_verity:read/3` as the one funnel through which the
  EROFS reader reads blocks, which passes them through unchecked until M11
  adds the hash check inside it, and CRC-32C among the per-byte primitives,
  with its fuzz target
  ([design-runtime.md](design-runtime.md#per-byte-primitives));
  read-only images in the EROFS format, one per release: the EROFS reader
  in Erlang, preloaded in both runtime images, with its fuzz target;
  fsimg as the packer's host tool, which writes and verifies each image, and
  the packer's disk image for QEMU, laid out by the ABI file's medium
  layout.
* **One practical data store.** littlefs as the stopgap read-write file
  system behind `erx_fs`'s callback module, a NIF of the system domain that
  a worker process calls on a dirty scheduler while the volume's owner
  process serves its block requests through the block driver, with a fuzz
  target for its images, on the data partition
  ([design-storage.md](design-storage.md#read-write-storage)); its
  sub-space port form lands in 1b-E, with the storage domain, behind the
  same callback module.
* **Booting from the disk image.** The QEMU harness's normal boot, without
  trials: it plays the firmware, reads the record from the disk image with
  its slot parser, which has its fuzz target, boots the slot the record
  names and writes the boot value into `/chosen`, from which the root task
  builds the machine page, so the device service grants the slot's EROFS
  windows
  ([design-platforms.md](design-platforms.md#slots-and-the-boot-selection-record));
  the harness's trials follow with M12.

**Exit criteria.** Every EROFS image the packer writes passes fsimg's
verification, and the reader's tests over fsimg's fixture images
pass; every read of the EROFS reader goes through
`erx_verity:read/3`, which a build check enforces with its seeded
violation; a file synced under `/data` survives
a power cut after the sync and the next boot, under HVF; the
build check that only the driver's modules reference the device NIF
passes, with its seeded violation; the partition-table parser, the EROFS
reader, littlefs's
images and the per-byte primitives run their fuzz budgets clean.

**Baseline.** M6 records the throughput and commit latency of the EROFS
reader, of littlefs and of the block driver on QEMU with
`tools/erx bench fs` and `tools/erx bench blk`, under HVF and TCG apart,
as the baseline G6 compares against.

## Track K: erXos's kernel

**Goal.** erXos's own C17 kernel, implementing first the interface the
stopgap implements and then the rest of the interface, from
[design-kernel.md](design-kernel.md).

* **The pilot**, from gate GK1, starting before Phase 1 is complete and
  running beside Phase 1b: host-only C17 cores, written from the design
  document with their host tests, fuzz targets and sanitizers, and timed:
  the object store, the capability table, attach, the release and
  deletion core, budget integration, the grace tracker and the page
  funnel as pure cores, and the chokepoints across them. The pure cores
  take and return no locks; the reaper's scheduling, the lock
  primitives, dispatch and QEMU are outside the pilot. The focused CBMC
  pilot checks its actual C cores, with the
  adoption criteria in [Verification work](#verification-work). The kernel
  pilot calibrates how long an agent takes from design to a
  reviewed, tested subsystem, which the plan then uses for the rest of the
  kernel.
* **The kernel**, from gate GK2, after the pilot and after 1b-A, with
  Phase 1's and 1b-A's tests and benchmarks baselined on the stopgap and
  the conformance roster written from the design, so that the roster
  covers the rows 1b-A's consumers use:
  Fiasco's process model with a kernel stack per thread and helping locks,
  the rest of the objects, memory windows in place of a copy funnel (no
  call takes a user address, and the kernel reads and writes the bytes a
  window names only through `erx_window_read` and `erx_window_write`),
  the shared C17 cores, the root task and the watchdog with the crash
  record in the layout the ABI file gives, the stack proof over every
  thread's kernel stack and every chokepoint check, booting Phase 1 and
  1b's boot image. Each mechanism lands with its conformance and hostile
  tests, and `tools/erx bench` measures its paths, the existence lock's
  contention and `tools/erx bench stop` among them.
* **The kernel's first part**, what the switch and M2 stand on, with the
  decisions in C17 cores:
  * capabilities with generations and per-type rights, with copies, closes,
    `erx_cap_pass` in its creator's case and deletion, which frees an object
    after an RCU grace period, as Fiasco does; budgets with guarantees, caps
    and walls (K32), as space banks, whose deletion deletes every object
    charged to them; capability transfer at
    an IPC rendezvous lands in M5's kernel part, with this IPC designed to
    add it without
    reshaping the rendezvous;
  * spaces, each with its parent, fault gate and label fixed at creation,
    threads (executors and workers), private and shared memory objects and
    the physical objects the kernel makes: the boot image, its slices
    (`erx_image_slice`), the time page and groups' shared areas; ceilings
    and reserves, W^X, faults to fault gates, `erx_space_stop` and exit
    records that arrive only once no thread of the space can run (K18), a
    stopped thread finishing the call it is in, or waking from its wait,
    before it dies; sealed paged objects, contiguous objects and physical
    objects created from device resources arrive with their first
    consumers;
  * IPC gates bound to one thread each, with labels and timeouts, a server
    running at its own urgency and on its own group's grant from its first
    instruction; IRQ objects bound to threads, or to groups with labels and
    listed on the groups' ready lists, passing with `TRIGGER` and never with
    `BIND`, so a holder can ring one and never take its deliveries; umtx;
    the early console; the time page; entropy; `erx_machine_end`;
  * the root task: the first space without parent or fault gate, the root
    capabilities at the ABI file's well-known slots, the boot information
    page flagged `ERX_BOOT_ROOT`, and the device-secret page with the status
    `no_key` ([design-kernel.md](design-kernel.md#the-root-task));
  * the watchdog: `erx_watchdog_pet` on the platform object, needing
    `POWER`, armed when the root task starts under `erx.watchdog`'s period,
    deadline and boot deadline, and the crash record, written to the early
    console and followed by the end of the machine through the firmware, for
    a missed deadline, a fault of the root task and its halt outside
    `erx_machine_end` ([design-kernel.md](design-kernel.md#the-watchdog));
  * groups in configuration C0: urgency levels, round robin within a level,
    park and wake with epochs, the executor rule; the quota pool's C17 core
    built and tested on the host, with target enforcement in configuration
    C1 ([design-scheduler.md](design-scheduler.md#park-and-wake));
  * above the kernel: `liberx`'s `erx` backend; `erx_root_main` building the
    programs a development manifest's partial boot names as domains through
    the domain library ([design-system.md](design-system.md#boot)); the
    domain library's production `erx_dom_plan_configured` core for native
    domains, built for the host as the packer's property-12 checker as well
    as for the runtime, validated whole and undone step by step
    ([design-system.md](design-system.md#the-domain-library)); the
    production startup plan `erx_root_plan` with its charge evidence, run by
    the packer and the kernel
    ([design-kernel.md](design-kernel.md#the-startup-plan-and-its-charge-evidence)),
    which replaces the Phase 1 root startup rule behind the packer's
    `Admitted` value before gate GK3; the conformance suite for every call
    in scope; the chokepoint checks that confine kernel calls to `liberx`;
    the stack proof and chokepoint checks over the C17 cores.

  Its criteria: the conformance suite passes under HVF on one and
  four CPUs; in each of those two configurations, two hostile native
  domains attack every call for ten minutes with malformed arguments, stale
  and wrong-rights capabilities, faults, floods and streams of thread kills,
  with threads pinned to every online CPU, each reports per-CPU progress
  counters on the console, and the harness checks that every CPU of every
  domain makes progress through the whole run and that the root task keeps
  petting the watchdog, with no kernel or root-task fault; the park
  protocol's exhaustive host model passes (S2); every call that may wait
  refuses an executor, umtx waits on private memory excepted (S3); a space
  stopped while its threads run, fault and call on every CPU posts exactly
  one exit record, after its last thread has finished its call or left its
  wait and died (K18); a server whose group's ceiling is 15 runs at most at
  15 while serving a caller at 40, and runs on its own group's grant from
  its first instruction (S5); the host test of `erx_tlb_plan` finds every
  removal invalidating what it made stale, each cleared table entry over its
  span in the walk caches and with the IOMMU's every-level form (K9); a pet
  from a thread without `POWER` is refused, and a boot that never pets, a
  pet stopped through the test-build hook, a fault of the root task and its
  halt each end the machine with a crash record whose cause names them,
  which the harness reads from the serial log (K31); the domain library's
  creation plan passes its host tests with a failure injected at each step
  and every object released; the packer refuses an image whose startup plan
  does not fit and the kernel refuses a boot whose charges disagree with it,
  each with a seeded case; the call decoder's fuzz target runs its budget
  clean; the park lock and the quota pool's host core pass their
  ThreadSanitizer runs; the C17 cores pass their host tests under ASan and
  UBSan.

  Its first measurements, under HVF and TCG: the null call, an IPC round
  trip through a gate within and across spaces, park and wake on one CPU and
  across CPUs, deadline-to-resume latency (`tools/erx bench timer`), boot
  time to the root task's start, and `tools/erx bench stop`, the stop of a
  space with threads in calls and waits on every CPU. They decide the timer
  slack and default time slice.
* **Deferred guarantees.** Every guarantee Phase 1 and 1b defer lands on
  erXos's kernel at the milestone named in
  [design-stopgap.md](design-stopgap.md#what-phase-1-defers).
* **The switch**, at gate GK3: the conformance suite, Phase 1 and 1b's
  transcript tests, the oracle and the benchmarks run on both kernels,
  differentially ([M7](#m7-the-stopgap-leaves)). The stopgap carries only
  Phase 1 and 1b's part of the interface, so the switch waits for nothing
  beyond Phase 1 and 1b's system. Each row the backend grows for Phase 1b
  names what the kernel's first part must implement by the switch, and a
  vCPU row, if the stopgap gains one, brings vCPU upcalls into the first
  part.
* **After the switch** the interface grows on erXos's kernel alone, each
  increment with its conformance and hostile tests: pauses, in their named
  states, for the job control of programs (track S), with their latency in
  `tools/erx bench pause`; the cooperation features of configuration C2
  (M8); the device interface, a PCIe bridge's windows, DMA windows, the
  IOMMU and MSI IRQ objects (M9's kernel part); copy-on-write children,
  copies of
  spaces by a sub-space's creator, and store tracking with
  `erx_mem_dirty`, by hardware dirty-state management where the CPU has
  it and by write-protect faults elsewhere (track Q); and the machine
  lease of a trial boot, the board's hardware watchdog reloaded from the
  kernel's timer, the crash region and the device-secret key read (M12).
  The security closure, M11, is the release gate for all of it.

## M7: The stopgap leaves

**Goal.** erXos's kernel boots Phase 1 and 1b's system and replaces the
stopgap Fiasco.

**Demo.** The same boot image boots on erXos's kernel and runs Phase 1
and 1b's system: the system shell and the live machine, files from EROFS
and littlefs, the Erlang command shell, domains over their connections,
programs over pipes, the POSIX-lite first part, the browser and the
desktop, drivers in their domains, erXos's F2FS and the network stack on
QEMU, with every test and benchmark it ran on the stopgap.

**Exit criteria.** Every conformance, transcript and oracle difference
between the two kernels, the transcripts compared from erXos's banner on,
is a bug fixed, a documented improvement with a test, or a bug in the
stopgap recorded as such, K26's "at once" among the improvements; the
scheduler and messaging benchmarks meet or beat the stopgap's; a page-table
walk after every test finds no writable and executable mapping.

**Gate GK3.** Decides the replacement, from the conformance suite and
Phase 1 and 1b's workloads: parity over Phase 1 and 1b's system, which is
all the stopgap carries, as every stopgap's replacement needs. The fork
leaves the tree with its `TODO.md` item; the dependency table drops it.
It also takes the measurements G5 and G9 defer to erXos's kernel: G5's
E-D3, E-D4 and full E-S2, with the absence of any kernel object per
lightweight process, and G9's interrupt latency and ring throughput over
the virtio-mmio drivers, repeated on erXos's kernel; and it decides
whether a program's start needs a cheaper path than one kernel
call per object.

## M8: Cooperation earns its place

**Goal.** Each cooperation feature measured against the plain baseline,
kept or dropped by its numbers, on erXos's kernel, and the shared
services' grants sized by the rule the measurements confirm.

**Demo.** `tools/erx bench ladder` runs workloads W1 to W7 under C0, C1
and C2 (each flag alone and together) and prints the table that decides
the defaults; and `erx:i()` shows the CPU time of a domain's requests to
each system service as that service's own processes report it, marked as
runtime-reported.

**Scope.** Published urgency, deferred preemption, status words and
idle-first wake placement in the kernel's scheduler core and in the
adapter, each a group flag under `erx.sched`; capacity advice and runs in
the resource policy; the receive boost; the sizing rule for a shared
service's grant and the per-client attribution the services report
([design-scheduler.md](design-scheduler.md#status-words-and-capacity),
[design-scheduler.md](design-scheduler.md#service-work),
[design-runtime.md](design-runtime.md#scheduling),
[design-system.md](design-system.md#resource-policy)).

**Exit criteria.** Every feature has its off switch and a test with it on
and off; E-S1 and E-S3 to E-S9 have recorded results; the exhaustive
models of deferred preemption and urgency resolution pass; under E-S5 a
flooding client slows a capped service's other clients by no more than its
admitted share, the service never exceeds its grant, and its per-client
report tracks the cycle-counter ground truth within E-S5's error, a seeded
misreport changing nothing but the report; under E-S8 an urgent client's
latency through a busy service sized by the rule stays within the policy's
bound; E-S9 finds the runs' shares on every CPU within one CPU; the
receive boost's derivation tests pass; a domain that rings a lane's
doorbell in a loop with an empty lane costs the receiver at most one pass
per ring, and the hostile runtimes run ten minutes without taking the CPU
time of their neighbours through the system domain or any shared service.

**Gate G8.** Decides, from E-S1 and E-S3 to E-S9: which features stay on
by default and whether any is removed; the default time slice, grace and
period; the capacity rules; the sizing rule's headroom for shared
services, and whether a service needs a child group per client class
([design-scheduler.md](design-scheduler.md#risks-and-open-questions)).

## M9: A driver is an Erlang process

**Goal.** Drivers as supervised Erlang processes over the device NIF, in
domains that hold their devices, restarted by their supervisors; the
PCIe domain with the PCIe enumerator, and the devices domain for the slow
devices; DMA confined behind the IOMMU. M9 lands in two parts: on the
stopgap as 1b-E, after 1b-A, and its kernel part on erXos's kernel, after
M7.

**Demo.** A block transfer and a network ping run while the block driver
process and then the network driver process are killed; each supervisor
resets its device and restarts the driver; the shell never notices. The
inspector shows every driver as a process with its device's registers by
name. On the stopgap the drivers run over virtio-mmio, unconfined, and the
ping joins the demo once 1b-G's network service answers it.

**Scope, on the stopgap (1b-E).** The storage domain, which holds the
block driver and the file systems from here, with littlefs as its
sub-space port over track S's port driver (1b-B)
([design-stopgap.md](design-stopgap.md#littlefs-in-the-storage-domain)),
and the part of the device service that gives it its device; the device service in full, with the
system manifest's placement of devices and its `/dev` tree
([design-system.md](design-system.md#devices)); the device NIF in full:
the device NIF's address rule, under which an unconfined device's memory
is the system domain's for the boot and a confined device's is freed only
after the kernel unbinds it from the device's window,
receive as a copy into a fresh binary at completion, so no term aliases
memory the device can write, transmit copies as per-byte C, interrupt
acknowledgement, and
the build check that register accessors are referenced only from the
device NIF ([design-runtime.md](design-runtime.md#the-device-nif)); the
block, network, GPU and input drivers in Erlang over virtio-mmio, each a
row of the stopgap's device records, in the storage, network and display
domains that hold their devices, unconfined, written after sDDF's model
of the driver-versus-policy split, with sDDF's published throughput as
the oracle and nothing imported, and M6's block driver among them; the
restart demo. Drivers run in their own domains rather than the system
domain, since that is the structure a person sees and the device
service's first real exercise; the unconfined DMA residual is the same
either way. No task other than the root creates a device object: the
domain library creates each device's register window, line
object and contiguous memory in the root and passes them to the holder,
which maps the window and binds the line to its own group, and at the
holder's end deletes the window's and the line's objects and keeps the
memory for the restarted holder
([design-stopgap.md](design-stopgap.md#device-records)); DMA stays
unconfined, since QEMU `virt` as the harness starts it has no IOMMU. The
Phase 1 manifest check allows these devices in development builds
([design-stopgap.md](design-stopgap.md#the-phase-1-manifest-check)), and
the device service's unconfined placement is
[design-system.md](design-system.md#devices)'s on the stopgap.

**Optional on the stopgap.** The host-tree domain of
[design-live.md](design-live.md#files-between-the-host-and-the-machine),
which holds QEMU's virtio-9p device with its own device role and driver and
serves the Mac's tree at `/host` to the domains the system manifest names
through the 9P bridge, is work 1b-E may pick up when a need for it appears.
It is no exit criterion of 1b-E or of any other item until then.

**Scope, on erXos's kernel (M9's kernel part).** The virtio console,
block and network drivers over virtio-pci, the move from virtio-mmio
being a device record and a DMA profile, not driver code; the PCIe
domain, `pcie@erxos`, whose enumerator, an Erlang process, alone holds
QEMU's PCIe configuration window and holds nothing else, parses
configuration space in Erlang with a fuzz target, and programs MSIs and
bus mastering at the device service's request, and the devices domain,
which holds the slow devices and no configuration space
([design-system.md](design-system.md#drivers)); a driver for QEMU
`virt`'s MSI frame in the kernel's platform layer, so MSIs reach
virtio-pci devices under HVF; DMA windows behind the IOMMU for virtio-pci
on the PCIe bridge's root bus, QEMU's one fixed bus, the only bus whose
requester ids the kernel trusts, with every other stream aborting
([design-kernel.md](design-kernel.md#dma-and-the-iommu)); and the device
interface these need, a PCIe bridge's windows, DMA windows and MSI IRQ
objects, on erXos's kernel with its conformance and hostile tests ([Track
K](#track-k-erxoss-kernel)).

The estimate derives from the parts: the device NIF with its envelope and
NIF glue, about 3,000 lines of C17 beside the generated accessors; and
about 5,000 lines of Erlang for the virtio drivers at a few hundred lines
each (sDDF's C drivers run 400 to 700 lines, and binary matching is no
longer), the PCIe enumerator with its fuzz target, the device service's
placement and `/dev`, the supervisors and the tests. The PCIe enumerator
and the MSI frame's driver are the kernel part's.

**Exit criteria, on the stopgap (1b-E).** A storage domain killed under
load restarts with no acknowledged write lost; a crash injected into
littlefs mid-write ends its sub-space port, whose owner restarts it and
remounts, with no acknowledged write lost; driver restarts under load
lose no acknowledged data, and a device reset after a driver's crash
returns every posted buffer to its pool; the drivers' descriptor parsers,
the GPU's responses and the input events among them, survive their fuzz
budgets, a hostile device model under QEMU writing malformed descriptors
and completions crashes at most the driver process and never the runtime;
`/dev` reads every device's status, and only the control facet's tree
accepts `ctl` writes; the chokepoint check over the register accessors
passes with its seeded violation.

**Exit criteria, on erXos's kernel (M9's kernel part).** Every criterion
of the stopgap's list passes again over virtio-pci; a confined driver
cannot DMA outside its window; a device given to a second domain while
the first holds it is refused; the PCIe enumerator's fuzz target runs its
budget clean; MSIs reach every virtio-pci device under HVF.

**Gate G9.** Measures, per device class, interrupt-to-handler latency
through the runtime's scheduler with `tools/erx bench irq`, the ring
throughput of each driver against sDDF's published figures for the same
device, `tools/erx bench blk` and the network driver's packet rate, and
the MSI path under HVF against wired interrupts. On the stopgap, in 1b-E,
its measurements are recorded with the stopgap named and decide nothing:
an interrupt there reaches a dispatcher through the backend's single
service thread, and a native shim admitted on that latency would plug a
gap of Fiasco that erXos's kernel closes. GK3 repeats them on erXos's
kernel, and the gate decides at M9's kernel part: completion batching per
device class, when virtio-pci replaces virtio-mmio, and, for each device
whose Erlang driver misses its timing or costs more than the stated
fraction of its throughput, a row in the driver table of
[design-system.md](design-system.md#the-driver-table) with its
measurement, which alone admits a native shim as a sub-space port;
without a row there is no exception. No row of the driver table is
decided from the stopgap's numbers.

## 1b-G: Networking on QEMU

**Goal.** Networking to other machines on QEMU `virt`, on the stopgap,
with erXos's own TCP/IP stack in Erlang as the network service from its
first release, along the [networking](design.md#networking) section of
design.md. The network service gets its design document before its code.

**Demo.** The network domain carries UDP echo and a TCP bulk transfer to
a Linux peer through the packet-path prototype under HVF; then, with
[M14](#m14-erxoss-network-stack) on QEMU, TLS, SSH and distribution
sessions to the peer run over erXos's stack, and a network domain killed
under load comes back, ending only its connections.

**Scope.** After 1b-E, whose network driver it uses. The network domain,
an Erlang release that holds the virtio-net device and its driver
process; the packet client and the Internet checksum among the per-byte
primitives; the **packet-path prototype**: Ethernet, IPv4, UDP and a TCP
data path in Erlang over the packet client, enough for UDP echo and a TCP
bulk transfer to a Linux peer, for gate GN-QEMU, built from the network
stack design's own modules (its codecs, credits, interface process and
the established-connection part of its TCP core), so the prototype is
the first piece of M14 and is not thrown away; then M14's first stage on
QEMU, grown from the prototype; TCP distribution to other machines, each
exposed domain a distribution node of its own, whose node name is
registered and resolved as the network service's design document defines
([design.md](design.md#networking)); and `crypto`, TLS and SSH on OpenSSL
3.5. No stopgap stack is ported: the stack is erXos's own from the first,
written in Erlang by translating the logic of FreeBSD's `netinet` and
`netinet6` at one pinned release, as the network stack's design document
specifies. Sockets are the oracle's last family that cannot
run, so 1b-G closes the full oracle on QEMU. The network domain's own
grant and its per-interface ingress budget are guarantees of erXos's
kernel, recorded as residuals here and checked on the boards with M12.

**Exit criteria.** The packet path and the Internet checksum run their
fuzz budgets clean; the oracle's socket cases run on erXos and compare
with stock OTP 29.1.2 case by case; M14's criteria for its first stage
hold on QEMU.

**Gate GN-QEMU.** Measures the packet-path prototype: UDP echo rate and
latency, and a TCP bulk transfer's throughput and CPU time, against a
Linux peer, on QEMU under HVF, with the host, accelerator, QEMU version,
compiler and flags recorded. The target is line rate at 1 Gb/s, 81,274
full-size frames a second each way, 12.3 us a frame (computed from IEEE
802.3's framing). It separately tests minimum-size frames (about 1.49
million frames/s at 1 Gb/s, 1e9 / (84 * 8), including preamble and
inter-frame gap), invalid packets, reassembly and connection floods, full
duplex and overload recovery. These are arithmetic offered-load targets,
not measured throughput. Unowned traffic has a finite per-interface CPU
and memory budget before a client can be identified; reserve control
progress while dropping excess traffic. Report p50, p99 and p99.9 and
peer progress under load on matched setups. On the stopgap every
interrupt, acknowledgement and doorbell passes the backend's one service
thread, so these numbers are a baseline, recorded with the stopgap named,
and decide nothing: a native fast path admitted on them would work around
the stopgap rather than the stack. M14 is written in Erlang throughout
meanwhile. GK3 repeats the measurements on erXos's kernel and decides
there whether TCP's fast path in erXos's stack needs native code
([design.md](design.md#networking)); GN-board at M12 confirms or reopens
that decision on the Pi 4.

## M10: Users without a container runtime

**Goal.** Principals with budgets, CPU shares and quotas; each user's
default domain.

**Demo.** Two users log in; each gets a domain; one exhausts its memory and
another its CPU share; only their own domains end or slow down.

**Scope.** The principal service, a session domain per login of every
principal over track S's session domain, quotas and ceilings; principal
groups and budgets in the resource policy; facets for every service; the
console's login, which checks passphrases only from M11, when the vault
arrives, and the system-shell facet, which the console grants to a login
at a secure line and holds itself
([design-live.md](design-live.md#the-console)); the host link's configured
facet sets; supervised domains and their code overlays, kept per principal
as manifests in the code store, each principal's hot store and overlays in
the principal's own directory on the data partition that M6 brings, none
for the boot image's manifest, with the code service's
decoder of what it reads back and its fuzz target
([design-live.md](design-live.md#the-code-store)); per-principal quotas on
the data partition.

**Exit criteria.** Quota and ceiling tests per limit, a session's programs
within its budget included; a user's domain at its limits leaves the
other user's latency within its budget (W5); a release-configured build's
console lines each show a login, a principal the manifest does not name
for the system shell gets none, and a lock or a log out at the UART ends
its system shell; a host-link session holds exactly its configured facets;
an overlay survives its domain's restarts and the machine's reboots, and
is dropped when its release changes; each principal's hot store answers
only for its own blobs; the code service's decoder of overlays and stores
runs its fuzz budget clean.

## Track Q: The second tier

**Goal.** What programs that cannot be changed expect of a UNIX, toward
what QNX offers: `fork`, the `exec` family, shared libraries, mappings of
files, and pseudo-terminals with process groups and sessions, on which
full-screen programs run
([design-programs.md](design-programs.md#the-second-tier)).

**Demo.** In a terminal session, toybox's `sh` runs a script with
subshells, command substitution and a pipeline; `vi` edits a file and
`less` pages through a log, each leaving the console as it found it; a
dynamically linked program loads a library with `dlopen`; and two
programs of one session that map one file `MAP_SHARED` see each other's
stores at once, and `msync` makes them durable.

**Scope.**

* `fork` by eager copy: the session's port driver copies the program's
  sub-space with `erx_space_copy`, which only a sub-space's creator may
  call, holds the parent while it copies, charges the session's budget for
  the child's memory as it goes and decides each mapping by its object's
  kind, the child's first thread starting at the entry and argument the
  driver names; `liberx`'s fork with its prepare, parent and child steps
  and `pthread_atfork`; the child's pipe ends installed by the pipe server
  and its grants derived at the servers, all or none; `vfork` as `fork`;
* the `exec` family: the quiesce, which parks the other workers once every
  closed wait has ended; the session building the new image under the
  program's anchor, with a channel of its own, while the old one waits,
  and moving what the new image keeps once the old image has closed what
  it does not hand over; the switch at the old image's exit record; the
  program record in the handler, which keeps the program's identity, its
  children and its signal reports across images, and to which the old
  image hands its frozen descriptors in `{exec}`;
* shared libraries: `erx_exec` as the dynamic linker, from musl's adapted
  to map file objects, with `dlopen`, `dlsym` and `dlclose`, a library's
  writable segments as copy-on-write children of its sealed object;
* mappings of files: `MAP_PRIVATE` as copy-on-write children of sealed
  objects, or a private copy of a file some program maps for writing; and
  `MAP_SHARED` served by the session: one memory object per file that any
  of its programs maps shared, owned by a mapper process of the session,
  which fills it from the file server with ordinary reads before any
  mapping covers the range, and maps it into each program that maps the
  file. Every descriptor read, write and size change of the file by the
  session's programs goes through that object, a write going to the
  object and to the server together. The mapper learns from the kernel's
  store tracking, `erx_mem_dirty`, which pages were stored to, and writes
  those back with ordinary writes at three points: `msync`, where
  `MS_ASYNC` starts the write-back and returns; every close of a mapping's
  open (a program's last `munmap` of the file, its `exec` and its end);
  and the last `close` of the file. A second session's mapping of the
  file is its own copy, and an Erlang domain maps nothing shared
  ([design-files.md](design-files.md#shared-mappings));
* pseudo-terminals that a program holds, over the session's line
  discipline, process groups and sessions, and `SIGWINCH`
  ([design-programs.md](design-programs.md#the-terminal));
* toybox's applets that need these: `sh`, `vi`, `less`, `login`, `setsid`;
* descriptors passed with `SCM_RIGHTS` over `socketpair`.

**Exit criteria.** musl's `libc-test` and the Open POSIX Test Suite pass
their `fork`, `exec`, `dlopen` and `mmap` cases, or each failure is
classified; toybox's tests pass for the second tier's applets; a forked
child holds no capability outside its type's pass set and executes only
code its parent had mapped, and a fork whose copy its session cannot pay
for fails with `ENOMEM` at the call, the child undone; a child survives
its parent's `exec`, and an `exec` leaves no fid of its close-on-exec
files open at any server; an `exec` that races a sibling's end, a pipe
peer's close and signals delivers every report to the image it was made
for, and abandons no closed wait; no program maps code it can write, a
library with text relocations being refused; the programs of one session
that map one file, or read and write it through descriptors, see one
another's stores at once, every descriptor read, write and size change of
the mapped file going through the mapper's object; two sessions that map
one file each hold their own copy and see each other's stores only after
write-back, page by page, a documented difference with a test; stores
reach the file at `msync` (where `MS_ASYNC` starts the write-back and
returns), at every close of a mapping's open and at the last `close` of
the file, each point with a test that reads the file through another
domain after it; an access through a mapping to a page
wholly past the file's end reads zeros, where Linux raises `SIGBUS`, a
documented difference with a test; a storage service killed under a
shared mapping leaves `msync` and the last `close` failing with `EIO`,
and the last `munmap` returns `EIO` on a failed write-back though the
mapping is gone; `vi` and `less` draw on a pseudo-terminal, and the
shell's prompt works when they end or stop.

**Gate GQ.** Measures `fork` of 10, 100 and 1,000 MiB of committed memory
under HVF against `fork` on Linux in a guest (`tools/erx bench fork`), and
the start of a dynamically linked program against a static one. Decides
whether `fork` grows a copy-on-write path over the kernel's copy-on-write
children, the optimisation the eager copy does without.
It also measures the session's shared mappings with
`tools/erx bench mmap`, for files of 64 KiB to 1 GiB: the fill, a read of
the mapped range before it is installed, and the write-back,
`erx_mem_dirty` and the page writes, at `msync`, at the last `munmap` and
at the last `close`, each against reads and writes of the same bytes
through a descriptor, and, on CPUs with hardware dirty-bit management,
the fold of the hardware's dirty bits into the object's stored marks
(`erx_vm_fold`) at `munmap` and at `exec` over large shared mappings
([design-kernel.md](design-kernel.md#virtual-memory)). Record charge
failures and the peak memory of the session's objects, not just touched
pages. These measurements decide whether the fill and the write-back
points of the shared mappings meet the named application corpus.

## M11: Security closure

**Goal.** A release build that may run untrusted code.

**Demo.** A release build boots without the development banner on erXos's
kernel and asks for a login on its console; an Erlang driver runs behind
an IOMMU window; the logged-in session holds only its principal's facets.

**Scope.** A review of every residual risk in
[design.md](design.md#residual-risks); every fuzz target run at its full
budget; ASan, UBSan and TSan clean on the host builds and a UBSan kernel
through the QEMU suite; the external review; unconfined DMA refused unless
configured, device by device, and each unconfined device in a domain of
its own; hostile code in the sub-spaces of a domain holding `SPACES`, and
a domain that churns sub-spaces
([design-kernel.md](design-kernel.md#security)); the hash check of EROFS
images: the packer's dm-verity version 1 hash tree for each image and the
root hash, salt and data-block count in the manifest's `image` records,
and the check inside `erx_verity:read/3`, the funnel M6 built, so the
reader parses only blocks that passed their image's tree (E1), with the
hash-checking reader's fuzz target
([design-storage.md](design-storage.md#invariants)); credentials for
principals: the vault in its first form, whose only credential is one
passphrase slot per principal and whose only sealing backend is `none`,
in its domain, without a crash area, created by the domain library with
`ERX_DOM_SECRET` from the one release the boot image marks with
`ERX_ENTRY_SEAL`, which receives the sealing page, with a master key per
principal wrapped by the slot, the passphrase stretched by OpenSSL 3.5's
Argon2id (provisional parameters, under a fixed ceiling) within its
limits per name and per terminal and answered after one login envelope,
each file changed only through its one owner and published with a
checkpoint, and the `erx_seal` interface with its `none` backend, behind
which the `device` and `tpm` backends join at M12; the vault's files on
the vault's partition, served by a storage domain of its own whose only
client is the vault, on littlefs, the stopgap until erXos's F2FS, so
principals' files and the machine keys persist across boots from here;
`tools/erx bench login` on QEMU under HVF, with TCG reported apart, which
sets Argon2id's parameters against a budget of about a second; the fuzz
target of the vault's file decoder; OpenSSL 3.5 and the update
signature's small verifier pinned and built
([design.md](design.md#dependencies)).

**Exit criteria.** No open CRITICAL or HIGH finding; every residual risk
either fixed or recorded in `TODO.md` as accepted, with its reason. Every
EROFS image the packer writes passes `erx_verity`'s check on the host; one byte flipped in an
image fails the reads of its block with `eio` while every other file reads
on; the hash-checking reader runs its fuzz budget clean. Release images are
built with exactly LLVM 23.1.3, and their SHA-256 hashes are published, so
anyone can rebuild an image with that release and compare the bytes.

Closure includes the receiving funnel and the services behind it: the
hostile-runtime suite at the funnel of every runtime, ERTS and native,
at its full duration; the facets' generated admissions and their bypass
checks, with handles minted from a facet's own scope in place of bare
request names; the export table's lifetimes, a pid's with its process and
an alias's with its deactivation; every shared service on a grant capped
and sized by the rule G8 confirmed, with E-S5's and E-S8's results
recorded; the device NIF's property tests over post, complete, release
and reset on the hosted backend, a seeded release-while-posted failing;
and the chokepoint checks of the funnel, the device NIF's accessors and
the domain library's one releasing function, each with its seeded
violation. Backend closure requires hard confinement, externally enforced
deadlines, the declared resource-wide failure outcome and I/O
reconciliation before reuse; a failed volume may fail its clients.
Measure ordinary-domain, service and backend paths separately.
The reference permutation's small AES implementation is selected, licence
reviewed, version/hash pinned and checked against FIPS 197 vectors before
that runtime feature is enabled; source counters, image identity, exported
aliases and generation retirement have exhaustion tests. Host-link tests
exercise 128-bit session identifiers, counter exhaustion, restricted local
transport access and rejection of unauthenticated network exposure.

The hardware closure records the exact supported SMMUv3 and platform
evidence for loader quiescence/drain, closed initialization, ATS rejection,
sync ordering, the hold of a confined device's memory until its window's
invalidation completes, and stream reuse. Specification citations alone
do not replace executable tests. The Pi 4 port later applies the same
criterion to its unconfined-DMA profile.

## M12: Storage, networking, boards

**Goal.** Storage that survives power cuts, system updates that leave a
bootable system whatever happens, networking to other machines, and the
first boards, along [design-storage.md](design-storage.md) and the
[networking](design.md#networking) and [portability](design.md#portability)
sections of design.md. The network service and its stack come from
[1b-G](#1b-g-networking-on-qemu) on QEMU; M12 brings them to the boards.

**Demo.** A Raspberry Pi 4 boots erXos from its SD card; a file written
and synced survives a power cut; a system update arrives over the network,
its trial boot loses power and the old system comes back, and the next
trial commits after a healthy boot; the system domain killed during a
trial boots the committed slot.

**Scope.**

* **Storage on the boards.** M6's storage over each board's storage
  driver below, an Erlang driver over the device NIF in the storage
  domain, on a boot medium laid out by the ABI file's medium layout; the
  slot writer's Erlang release.
* **System updates.** The slot writer and the update service; the
  TLA+/TLC update model, its invariant-to-implementation mapping and the
  exhaustive host test of the actual state machine against an independent
  oracle, with a power cut after every
  write and every reset; update manifests, signed with the release key in
  release builds and with the development key that the build embeds in
  development builds, where the host tool signs an update it sends over
  the host link and the build tree one that arrives over the network on
  the Pi 5, which has no host link, so the update service has one path for
  the spare check; the manifests name the storage formats their release
  reads, which the update service checks against the running system's
  before it writes anything; a trial boot that writes nothing but the
  record, its file systems mounted read-only without recovery, and the
  reset after a commit; the ordered end of the machine, which ends the
  vault's TPM use and freezes the storage services before a trial or any
  other end ([design-system.md](design-system.md#shutting-down)); the
  machine lease that the kernel takes on a trial boot, K19 and
  `ERX_END_TRIAL`; the QEMU harness playing the firmware's trial request,
  beside the normal boot it plays from M6; and the packer's slot images.
* **Keys.** Key facets, their exact purpose checks and their fuzz target,
  erXos's key callback module and `sign_fun`, and the daemon's host-key
  signing added to `ssh`; the vault's partition on the boards' media; the
  `device` backend on both boards (the platform layer's boot-time read of
  a provisioned OTP key, the device-secret page, the sealing page derived
  by the root-task entry); the `tpm` backend under QEMU (the TPM driver
  for `tpm-tis-device` in the vault's domain, the vault's TPM 2.0 client,
  its response decoder's fuzz target, and the storage key trusted on first
  use, tested against swtpm); `tools/erx bench login` on the Pi 4, which
  confirms or lowers the parameters
  ([design-system.md](design-system.md#the-vault)).
* **Networking on the boards.** The network service, its stack and its
  sessions come from [1b-G](#1b-g-networking-on-qemu) and
  [M14](#m14-erxoss-network-stack) on QEMU; M12 brings them to the boards
  over each board's network driver below, with the network domain's grant
  and per-interface ingress budget enforced by erXos's kernel, and
  confirms the packet path's numbers on the Pi 4 at gate GN-board.
* **Boards.** The Raspberry Pi 4 Model B, then the Raspberry Pi 5, as
  [design-platforms.md](design-platforms.md) describes them: each board's
  interrupt controller, console UART, random generator, hardware watchdog
  and firmware mailbox, and the Pi 5's MSI frame, in the kernel's platform
  layer, with the kernel's device table; the hardware watchdog armed
  before the root task starts and reloaded from the kernel's timer for as
  long as the kernel's own deadline on the pet has not passed, so a kernel
  hang resets the board too
  ([design-platforms.md](design-platforms.md#the-watchdog)); the crash
  region, `erxos,crash-region` under `/reserved-memory`, read at the next
  boot into the root task's information
  ([design-platforms.md](design-platforms.md#the-crash-record)); the Pi
  4's firmware for starting CPUs and ending the machine; boot through the
  Raspberry Pi firmware with its boot selection, trial boot and watchdog
  settings; the boot probe on each board, recorded in a research record,
  which measures the time to the system runtime's first pet, confirms
  whether the crash region survives `SYSTEM_RESET`, and confirms which
  slot a watchdog reset boots; the system manifest of each board's release
  configuration, which gives every unconfined device a domain of its own,
  since neither board's tree confines its DMA devices, puts the TPM's SPI
  controller in the vault's domain
  ([design-system.md](design-system.md#devices)), gives PCIe
  configuration space on a board that drives a bridge, the Pi 5, to the
  PCIe domain alone (the Pi 4 drives none and has no PCIe domain), and
  passes the manifest check; Erlang drivers for each board's storage and
  network devices, with their reset sequences, each measured for its row
  or absence of a row in the driver table (G9); the IOMMU support a board
  needs beyond what QEMU `virt` needs, among it the handoff of an SMMUv3
  that live firmware left configured and the evidence that DMA issued
  before the kernel's entry has drained, written and tested against the
  loader of the first board that has an SMMUv3
  ([design-kernel.md](design-kernel.md#dma-and-the-iommu),
  [design-arch-aarch64.md](design-arch-aarch64.md#iommu)); each
  board's entries in its DMA contract confirmed, and its
  asynchronous-error injection test run, before drivers run on it
  ([design-platforms.md](design-platforms.md#dma)); and the **board rig**:
  a serial capture, a power relay and an SD-card switch under the same
  harness and deadlines as QEMU, so a board's tests run unattended. QEMU's
  `raspi4b` model, under TCG, serves the kernel's early bring-up; it has
  no PCIe or Ethernet, and QEMU has no Pi 5 model.

**Exit criteria.** The update state machine's exhaustive test passes with
a power cut after every write and every reset; a file synced under
`/data` survives a power cut at every step of a scripted write load,
under HVF, and a block error injected under littlefs mid-write
fails that operation with an unknown outcome reported and no
acknowledged write lost; on both boards, through the
board rig, a trial that panics, hangs, calls `halt/0`, loses power or
loses its system domain boots the committed slot next, and a damaged
boot-selection record is tried in place; a stopped watchdog pet on each
board resets it with a crash record, and the next boot's inspector shows
the record where the region survives; both boards boot with good entropy;
the boards' drivers' descriptor parsers, the update manifest's decoder,
the vault's purpose checks, its
file decoder and its TPM client's response decoder run their fuzz budgets
clean; an overlay persisted on the data partition is dropped once a
system update changes its release; the vault's tests against stock OTP
peers pass, its `tpm` backend passes against swtpm under QEMU, a file
copied to another board opens no slot under `device`, a file forged under
`none` logs no one in from afar under `device` or `tpm`, and a Pi 4 login
fits its budget; on each board a storage domain killed under load
restarts with no acknowledged write lost, and a network domain killed
under load restarts ending only its connections. M11's closure criteria
hold again over M12's new surface: every new fuzz target at its full
budget; ASan, UBSan and TSan clean on the new host builds; every residual
risk the boards add reviewed; and an external review of storage, updates,
networking and the boards, as the ground rules require of everything
after M11.

**Gate G12.** Measures throughput and commit latency on the Pi 4's SD
card with `tools/erx bench blk` and `fs`, against G6's on QEMU, boot time
on both boards to the shell and to the first pet, the trial path's
timings, and slot images' sizes against the boards' media. Decides the
default of `erx.trial_deadline`, the boot deadline of `erx.watchdog` on
each board, and whether images need compression.

**Gate GN-board.** Repeats GN-QEMU's measurements of
[1b-G](#1b-g-networking-on-qemu) natively on the Pi 4: UDP echo rate and
latency, and a TCP bulk transfer's throughput and CPU time, against a
Linux peer and against Linux's stack on the same board, with the host,
accelerator, compiler and flags recorded. The target is line rate at 1
Gb/s, 81,274 full-size frames a
second each way, 12.3 us a frame (computed from IEEE 802.3's framing).
It separately tests minimum-size frames (about 1.49 million frames/s at
1 Gb/s, 1e9 / (84 * 8), including preamble and inter-frame gap), invalid
packets, reassembly and connection floods, full duplex and overload recovery.
These are arithmetic offered-load targets, not measured throughput. Unowned
traffic has a finite per-interface CPU and memory budget before a client
can be identified; reserve control progress while dropping excess traffic.
Report p50, p99 and p99.9 and peer progress under load on matched setups.
Confirms GK3's decision whether TCP's fast path in erXos's stack is
Erlang or native code ([design.md](design.md#networking)), or reopens it
with the board's numbers.

## M13: erXos's F2FS

**Goal.** erXos's own read-write file system, F2FS implemented in Erlang
from its on-disk format, replacing littlefs at parity
([design-storage.md](design-storage.md#read-write-storage)). It lands on
QEMU as 1b-H, after M6 alone, at the lowest priority of Phase 1b and only
when capacity is idle, since it is not user-visible; its Pi 4 half comes
with M12.

**Demo.** On QEMU, erXos's F2FS keeps a disk's files through power cuts,
and the Linux guest mounts the same partition image; with M12, an
installation brings erXos's F2FS to the Pi 4, whose files survive power
cuts and a later update's failed trial.

**Scope, on QEMU (1b-H).** The clean-room specification of the format, of
the cleaner's policies and of a read-only mount without recovery, as
Linux's `norecovery` mounts for a trial boot, written by one author from
Linux's documentation and sources who implements none of it, and the
implementation, in Erlang, from it alone; the feature bits it implements,
refusing the rest; the cleaner; the Linux oracle guest with `fsck.f2fs`;
the power-cut harness; the fuzz target; legal review of the clean room
before a product ships it.

**Scope, with M12.** The installation that brings erXos's F2FS, which
creates the data partition and the vault's partition afresh, with nothing
littlefs wrote carried across, and the update service's refusal of an
update whose storage formats differ from the running system's
([design-storage.md](design-storage.md#system-updates)).

**Exit criteria, on QEMU (1b-H).** Every image erXos's F2FS writes, and
every state of the power-cut harness, passes `fsck.f2fs` and mounts in the
Linux guest at the last completed checkpoint with every acknowledged
`fsync`; a read-only mount without recovery writes nothing, on erXos's
F2FS and on Linux's mounted with `norecovery`; the file-semantics corpus
agrees with littlefs and with Linux's F2FS, every difference a bug fixed,
a documented improvement with a test, or a bug in littlefs recorded as
such; the fuzz target runs its budget clean.

**Exit criteria, with M12.** The partition after a failed trial is byte
for byte the partition before it; the installation and the update
service's refusal have their tests on the Pi 4; and M11's closure holds
over what M12 adds, as the ground rules require.

**Gate G13.** Measures erXos's F2FS against littlefs over the
file-semantics corpus and against Linux's F2FS in the oracle guest, the
power-cut harness's results, and throughput, commit latency and the
cleaner's overhead, on QEMU in 1b-H. It decides the replacement of
littlefs there on the corpus, the oracle guest and the power cuts alone.
Its throughput, commit latency and cleaner numbers on the stopgap, whose
block path pays a service round trip per interrupt and acknowledgement,
are a baseline recorded with the stopgap named; the Pi 4's SD card
numbers on erXos's kernel at M12 are the first that can reopen the
decision.

## M14: erXos's network stack

**Goal.** erXos's own TCP/IP stack, written in Erlang, in the network
domain, as the network service's stack from its first release
([design.md](design.md#networking)). It lands on QEMU in
[1b-G](#1b-g-networking-on-qemu), after the packet-path prototype, and on
the boards with M12. No stopgap stack precedes it, so it is accepted
against FreeBSD's stack, whose logic it translates, rather than replacing
one.

**Demo.** TLS and SSH sessions and distribution sessions run over erXos's
stack, on QEMU and then on both boards, every connection a process the
inspector shows, and a network domain killed under load comes back.

**Scope.** The network stack's design is
[design-network-stack.md](design-network-stack.md): FreeBSD's default
TCP stack translated into Erlang, read from FreeBSD 15.1
(`release/15.1.0-p6`, `95719d8a`) and pinned at FreeBSD 16.0-CURRENT
(`main-n285245`, `975e3605`) with the changes between the two that the
wire can see ported, its processes and packet path, grants and sockets,
and its verification. TCP's fast path in native code, behind the same process
interface, only if GK3 decides so on erXos's kernel. The work comes in
two stages, the design's core and then its extensions
([Scope](design-network-stack.md#scope)):

* **First stage, the core.** Ethernet II; ARP; IPv4 with reassembly,
  fragmentation on output and ICMP; IPv6 with extension headers,
  reassembly, ICMPv6, neighbour discovery, duplicate address detection,
  autoconfiguration with RFC 7217 identifiers and the narrow MLDv2
  listener; static configuration and DHCPv4; loopback; UDP; TCP with the
  design's defaults (syncache and cookies, RFC 5961, RFC 6528, SACK with
  RFC 6675 recovery and PRR, limited transmit, IW10, window scaling,
  timestamps and PAWS, ECN in FreeBSD's default mode, path MTU discovery,
  keepalive and persist, buffer autosizing, TIME-WAIT with RFC 1337 and
  RFC 6191, reassembly caps, NewReno and CUBIC); the grant, its limits and
  its account; `gen_tcp`, `gen_udp` and `inet` through the `erx` socket
  backend; the POSIX socket protocol; the resolver operation; the port
  mapper; distribution to other machines, over TLS alone in release
  builds; the decoders' fuzz targets and `decode_packet`'s, run on the
  host's stock OTP; the explorer and the syncache properties; the two
  packet-script runners, FreeBSD's TCP test suite with nplab's packetdrill
  in a FreeBSD 15.1 guest and erXos's own runner, with erXos's own scripts
  run on both; and the traffic tests against the FreeBSD guest and
  Linux's stack. In this stage redirects are ignored, the multicast
  options answer `{error, enotsup}`, and `socket:open` answers
  `{error, enotsup}`, a documented difference with a test, with OTP's
  socket suites expected failures, by the owner's decision that `socket`
  comes after `gen_tcp`, which `ssl`, `ssh` and distribution use instead.
* **Second stage, the extensions.** The `socket` and `net` modules over an
  Erlang `prim_socket`, and OTP's socket suites; raw ICMP sockets for
  `ping`; checksum offload; one interface process per receive queue
  where the device has several; the host cache; AccECN; ICMP and ICMPv6
  redirects accepted as FreeBSD accepts them; 802.1Q VLANs; RFC 8981
  temporary addresses; multicast with IGMP and full MLD.

Outside M14, later, behind the stack's seams: RACK-TLP as a loss module,
deferred by the owner's decision, with the default stack as the
reference; BBR with pacing; DCTCP; TCP Fast Open.

**Exit criteria.** For each stage: every difference between erXos's
stack and FreeBSD 15.1's over the network test corpus is a bug fixed or a
documented difference with a test; every packet script's verdict on
erXos's stack equals its verdict on FreeBSD 15.1 in the guest, or its
difference is documented with a test; OTP's `gen_tcp`, `gen_udp` and
`inet` suites, and in the second stage the `socket` suites, compare with
stock OTP 29.1.2 case by case; the packet
decoders run their fuzz budgets clean; a network domain killed under load
restarts ending only its connections, on QEMU as a behaviour and on the
boards with the domain's grant enforced; and, on the boards, M11's
closure holds over what M12 adds to the stack, as the ground rules
require.

**Gate G14.** Measures the corpus's differences from FreeBSD's stack,
and throughput, latency and memory of erXos's stack against FreeBSD's and
Linux's, on QEMU in 1b-G, where the corpus and the packet scripts accept
the stack and the numbers, taken on the stopgap, are a baseline; and on
both boards at M12, on erXos's kernel, which confirm the acceptance with
their numbers.

## Decision gates

| Gate | Milestone | Measures or asks | Decides |
| --- | --- | --- | --- |
| G0 | M0 | the Fiasco set's licence scan and link closure; `lld` installed | what enters the tree, and the GPL-headed files the stopgap keeps |
| G3 | M3 | W1 against stock OTP; footprint; boot time to the shell | the baseline |
| GK1 | before Phase 1 is complete, beside Phase 1b | the pilot's time and defect rate | the pace of the rest of track K and of the plan |
| GK2 | after the pilot and 1b-A | Phase 1's and 1b-A's tests and benchmarks baselined on the stopgap, the conformance roster written from the design | the start of erXos's kernel in full |
| GK3 | M7 | the conformance suite, Phase 1 and 1b's transcript tests, the oracle and the benchmarks on both kernels; G5's E-D3, E-D4 and full E-S2; G9's latency and throughput and GN-QEMU's packet-path measurements repeated on erXos's kernel | the replacement of the stopgap; G5's provisional decisions confirmed or revised, the death path's batching and `system_queue`, and no kernel object per lightweight process; whether a program's start needs a cheaper path; whether TCP's fast path in erXos's stack needs native code |
| G2 | M2 | early E-S2 (kernel thread switch, IPC round trip through a gate, park and wake); E-S4 FIFO wake latency; E-S10 | whether the two-level model stands on erXos's kernel; NIFs that move to dirty schedulers |
| G5 | 1b-A, provisionally; confirmed at GK3 | on the stopgap: E-D1 and E-D2 (`tools/erx bench xdomain-pingpong`, `xdomain-throughput`); BeamAsm's speedup and footprint in an ordinary domain; translation time at a domain's start. At GK3: E-D3 and E-D4 (`xdomain-stall`, `domain-lifecycle`) and full E-S2 | provisionally: the runtimes' and the domain service's default table sizes, `cap_limit` among them; `lane` and the manifest's `system_lane`, the producer's wait rule, encoding straight into the lane; the funnel's allowance per step; the busy limit and the facets' limits; the ahead-of-time roster's triggers. At GK3: the manifest's `system_queue` and the death path's batching; no kernel object per lightweight process; the rest confirmed or revised |
| GP | track P | a program's start (`tools/erx bench spawn`) against its budget and `posix_spawn` on Linux; the `make`-shaped workload and `tools/erx bench pipe`, hosted and under HVF, the stopgap's numbers provisional | the channel's and data area's defaults; the handler's batching; one ring per write end (whether a program's start needs a cheaper path is GK3's) |
| G6 baseline | the end of 1b-D, on the stopgap | an idle domain's memory by kind, a session's and a program's, the session services' floor and a facet's heap; E-D1 and E-D2; `tools/erx bench fs` and `blk` against M6's baseline | nothing; it records the baseline G6 compares against |
| G6 | after M5's and M9's kernel parts | the system on erXos's kernel: an idle domain's memory by kind, a session's and a program's, the session services' floor and a facet's heap; E-D1 and E-D2; a program's start; isolation beside hostile domains; the EROFS reader's, littlefs's and the block driver's throughput and commit latency on QEMU (`tools/erx bench fs`, `blk`) against M6's baseline and the G6 baseline | whether the system meets the design's budgets before M8 and M10 build on it; G5's lane defaults and the facets' limits confirmed or revised |
| GW | track D's part 1, in 1b-C | a record view's round trip over the host tool's front end for the machine's record and a 1,000-child listing, under HVF and over a 115,200-baud UART host link | whether whole records stay on the wire or the web protocol gains a record difference |
| GD | track D's part 4, on its panel, once part 6 has run the Erlang renderer | the Erlang renderer's frame time on a 240 by 240 panel against LVGL's on the same panel; the parity test through both; part 6's Erlang renderer may record a QEMU frame time as a preview before the panel exists, deciding nothing | whether LVGL leaves the panels |
| G8 | M8 | E-S1 (the ladder C0 to C2), E-S3 to E-S9 | default cooperation features; time slice, grace and period; capacity rules; the shared services' sizing rule and whether a service needs a child group per client class |
| G9 | M9: recorded in 1b-E, decided at its kernel part | interrupt-to-handler latency per device class (`tools/erx bench irq`), ring throughput against sDDF's figures, `tools/erx bench blk`, the network driver's packet rate, MSIs under HVF; the stopgap's numbers recorded with the stopgap named | at the kernel part only: completion batching per device class; virtio-pci over virtio-mmio; each row of the driver table, which alone admits a native shim; no row from the stopgap's numbers |
| GQ | track Q | `fork` of 10, 100 and 1,000 MiB against Linux in a guest; a dynamically linked program's start against a static one's; the fill and the write-back cost of the session's shared mappings, files of 64 KiB to 1 GiB, with `tools/erx bench mmap`, against descriptor reads and writes; on CPUs with hardware dirty-bit management, the fold of dirty bits into the object's stored marks at `munmap` and `exec` over large shared mappings, with `tools/erx bench mmap` | whether `fork` grows a copy-on-write path; whether the shared mappings' fill and write-back points meet the corpus |
| G12 | M12 | throughput and commit latency on the Pi 4's SD card, against G6's on QEMU; boot time to the shell and to the first pet on both boards; the trial path's timings; slot images' sizes | the default trial deadline; the watchdog's boot deadline per board; whether images need compression |
| GN-QEMU | 1b-G, on the stopgap | the packet-path prototype's UDP echo and TCP bulk transfer on QEMU under HVF, against a Linux peer and line rate, recorded with the stopgap named | nothing; it records the baseline GK3 repeats on erXos's kernel |
| GN-board | M12 | the same on the Pi 4, against Linux's stack on the board and line rate | GK3's decision on TCP's fast path confirmed or reopened |
| G13 | M13: 1b-H on QEMU, the Pi 4 at M12 | erXos's F2FS against littlefs over the file-semantics corpus and against Linux's F2FS and `fsck.f2fs`; the power-cut harness; throughput, commit latency and the cleaner's overhead, on the stopgap a baseline; the Pi 4's SD card at M12 | the replacement of littlefs, on QEMU, from the corpus, the oracle guest and the power cuts; the Pi 4's numbers may reopen it |
| G14 | M14: 1b-G on QEMU, the boards at M12 | erXos's stack against FreeBSD's over the network test corpus and the packet scripts; throughput, latency and memory on QEMU, a baseline on the stopgap, and on both boards | the acceptance of erXos's stack, on QEMU; the boards confirm it |

A numbered gate takes its milestone's number: M7's gate is GK3, G6's
baseline ends track P's first part and G6 follows the kernel parts of M5
and M9, GN-QEMU belongs to 1b-G and GN-board to M12, and M1, M4, M6, M10
and M11 have none. The research
records are point-in-time reports and
use the gate names of the plan they were written against. The gates that
[research-baselines.md](research-baselines.md) names map here as follows:
its G2 to track K's first measurements (latency, measured there as
interrupt latency and here as deadline-to-resume latency), its G0 to M0
(repeating the ERTS
baselines with OTP 29.1.2), its G4 and G5 to G3 and G5 (the measurements
on erXos), and its G6 to G6 (the restricted decoder's cost under the
interpreter, within a frame's cost across a connection).

## Stopgaps

| Stopgap | Seam | Replaced at |
| --- | --- | --- |
| Fiasco near-stock, with `bootstrap` and `sigma0` | the kernel interface: `abi/erx_abi.txt` and `liberx`'s backends; in Phase 1 the Fiasco backend over Fiasco's own calls, the system domain's `liberx` owning every kernel object; in Phase 1b also lanes, sub-spaces, doorbells and device holders as rows of its root service | M7 |
| Fiasco's fixed priorities with no quota, grant or group enforcement | the scheduler core, `erx_group_configure` recording its grant | M7 (the scheduler), M2 (groups and quotas) |
| The Phase 1 manifest check and root startup rule | the packer's `Admitted` value and the manifest's properties | track K (`erx_root_plan`); M5, M9 and M11 (the properties, as [design-stopgap.md](design-stopgap.md#the-phase-1-manifest-check) lists them) |
| Virtio-mmio devices with ordinary interrupts and unconfined DMA, driven by the same Erlang drivers | DMA profiles; IRQ objects; the device NIF | M9's kernel part (virtio-pci with MSIs and the IOMMU), M11 (refused unless configured) |
| A host link holding every facet but the system-shell facet | session facet tables | M10, M11 |
| littlefs, the read-write file system of the data partition and the vault's partition, a NIF of the system domain in Phase 1 and a sub-space port of its storage domain from 1b-E | `erx_fs`, the storage service's file interface, and the port's channel | M13, by erXos's F2FS, in Erlang, at G13, decided on QEMU in 1b-H, through an installation that creates both partitions afresh, which comes to the boards with M12 |
| LVGL, the widget renderer on panels, a native program in a sub-space of the display domain | the renderer behaviour `erx_ui_renderer` and the generated reader of `ui.txt`'s operations | by the Erlang renderer, when GD admits it; GD is first measured on track D's part 4 panel |

The stopgap carries the rows of the backend's table in
[design-stopgap.md](design-stopgap.md#the-call-table), each in full, with
a documented weaker result, or as a refusal. No network stack is a
stopgap: erXos's own stack is the network service from 1b-G. A native
driver shim admitted by a row of the driver table
([design-system.md](design-system.md#the-driver-table)) is a stopgap
of the same kind as littlefs, a sub-space port behind the driver's
interface, and joins this table with its row.

## Critical path and parallel tracks

```text
Phase 1:   M0 --> M1 --> M3 --> M4 --> M6 --> track S (shell)
            |            ^
            +-> track H -+

Phase 1b, in order of its demos (backend rows, hosted backend too; BeamAsm beside 1b-A):
           1b-A domains on the stopgap
             --> session domain (1b-B's first slice) --> 1b-C track D part 1 (GW) --> part 2
             --> 1b-E M9 on the stopgap --> 1b-G network domain, GN-QEMU, M14 on QEMU
           1b-G's driver and stack in the system domain (from Phase 1, beside 1b-A)
             --> 1b-C track D part 3, the QEMU kiosk (with 1b-B's sub-space ports)
             --> 1b-D track P's first part --> G6 baseline --> toybox's applets (the rest of 1b-B)
             --> 1b-F track D part 5 --> part 6 --> part 7
           1b-H M13 on QEMU (any time; lowest priority)

Track K:   pilot (GK1), beside Phase 1b --> kernel in full (GK2), after 1b-A --> M7 (GK3, parity over Phase 1 and 1b)

Phase 2:   M7 --> M2 --> M5's and M9's kernel parts --> G6 --> M8 --> M10 --> M11 --> M12 (boards; M13, M14 and GN-board there)
           rest of track P --> track Q (after M7)
           track D: part 4, kiosks on boards (after part 3 and M12); part 8, the web on the network (after part 2, M10, M11 and 1b-G)
```

* Phase 1's critical path runs through M1, M3, M4 and M6; track H runs
  beside M1 and carries ERTS's port before the QEMU boot of M3; the shell
  follows M4.
* Phase 1b runs in the order of its visible demos: 1b-A; the session
  domain; 1b-E and 1b-G; 1b-C's parts 1 and 2; 1b-C's part 3 with
  1b-B's sub-space ports; 1b-D, then toybox's applets; 1b-F last, part 7
  after 1b-D. 1b-A comes first because every other item is a domain or
  runs in one. BeamAsm runs beside 1b-A, and 1b-H whenever capacity is
  idle.
* Track K's pilot starts before Phase 1 is complete and runs beside
  Phase 1b, since its cores are host-built C17
  with no shared seam and its calibration is needed whatever the order;
  the kernel in full starts after 1b-A, so its conformance roster covers
  the rows 1b-A's consumers use and each refusal of the backend names
  what M7 must add. Nothing in Phase 1b changes the kernel interface,
  only which rows the stopgap carries.
* Phase 2's critical path runs through M7, M2, the kernel parts of M5 and
  M9, G6, M8, M10, M11 and M12; the rest of track P follows its first
  part, and track Q follows track P and M7; M13 and M14, already on QEMU,
  reach the boards with M12.
* Track D runs beside the critical paths from the session domain on; no
  milestone needs it. Its first part, the browser over the host link,
  needs no device and comes first; the desktop follows 1b-E, and its
  later parts wait for the milestones that bring their programs, boards,
  logins and network.
* Host-buildable code (the C17 cores, the funnel and the lane reader, the
  domain library's plans, the device NIF's envelope, the pipe core,
  `erx_etf`, the draw core and codec, `erx_memdraw`, the terminal state
  machine, the widget tree's schema and difference, the web protocol's
  codecs) and its fuzz targets are written and tested on the host
  ahead of the milestone that integrates it.

## First pull requests

Each is small, adds its tests, and leaves `make check` green.

1. **Skeleton.** `Makefile`, `tools/erx` with `OptionParser` and the
   deadline runner (`gtimeout -k 10`, process groups, closed standard
   input, logs), the ASCII check, and `make check` running the Ruby tests.
2. **Fetch.** `deps.lock` and `make fetch` with SHA-256 verification into
   separate directories: the OTP 29.1.2 tarball, musl 1.2.6 and Arm's
   machine-readable specification.
3. **Imports.** OTP 29.1.2 into `otp/`, musl 1.2.6 into `musl/`, and the
   frozen Fiasco set into `fiasco/`, each with its licence notices and its
   `ORIGIN.md` with every file's hash, the change-notice check, and the
   licence scan of the Fiasco set.
4. **Oracle.** The host build of stock OTP 29.1.2 in both flavours and the
   suite runner that stores results case by case.
5. **QEMU harness.** Guests under deadlines with serial logs and awaited
   lines, both accelerators, QEMU `virt` configured as
   [design-platforms.md](design-platforms.md#qemu-virt) pins it; its first
   subject is the stopgap's own banner.
6. **ABI generator.** `abi/erx_abi.txt`, the Ruby generator, and the
   generated header for status codes, rights and limits, with golden tests.
7. **Hardware sources.** The SVD generator and the system-register
   extractor with golden tests, the generated-tree tests, and the SVD file of QEMU
   `virt`'s console UART as the first input.
8. **Boot image.** `tools/erx pack` writing `ERXPACK`
   deterministically, with its `NOTICES` file, the C17 validator built for
   the host, and its fuzz target, landing together.
9. **Benchmark harness.** `tools/erx bench` recording every condition, and
   the host baselines with OTP 29.1.2.
10. **Boot.** `bootstrap` loads an `ERXPACK` image and near-stock Fiasco
    starts `liberx`'s root entry, which prints a line and ends the machine.
11. **Memory.** The pool window, the range table, the VM calls and protect.
12. **Threads.** Threads with TLS, umtx, park and wake, each task's reaper,
    the watchdog.
13. **A second task.** The launcher, the root service, a JIT object's two
    aliases, a task's end.
14. **An interrupt.** IRQ objects, the dispatcher, the ready list.
15. **The production image.** The Phase 1 manifest check and a full boot to
    the point where ERTS would start.

## Beyond the plan

| Item | Why it waits | Decided |
| --- | --- | --- |
| An awklog form of the manifest check | it would express the manifest's relational rules (ownership, facet targets, boot order, rescue closure) as Datalog in place of Ruby, if that is simpler; nothing needs it, and awklog needs the user's approval | after Phase 1, with the user's approval of awklog, once M5 gives the manifest its rules for domains |
| Ahead-of-time translation of Erlang code | the JIT in each ordinary domain is the design; the roster keeps the triggers | on a trigger of [the options](design-runtime.md#running-erlang-code-the-options) |
| Landing pads in BeamAsm's generated code | hardening for generated code in ordinary domains | with M11's review, or on a board with branch-target protection |
| Direct dispatch of lightweight processes across domains, in the style of L4Re's vCPUs | an optimisation the proposal makes optional | only if E-D1 and E-S2 show the funnel's copy and the doorbell dominate |
| A weighted fair queue within a level | round robin with quotas and capacity meets the requirements | if E-S1 and E-S9 say otherwise ([design-scheduler.md](design-scheduler.md#risks-and-open-questions)) |
| A child group per client class inside a shared service | one capped grant per service, scheduled fairly by the service, is the design | if E-S8 shows one service's flooder starves an urgent client past the sizing rule's headroom |
| Other runtimes (Go, Lisp, nested runtimes) | "native for now"; the contract leaves room | when a use appears |
| A shell compatible with tcsh | the first version speaks rc's language, the user's choice | likely the command shell's next version |
| `system` and `popen` through a POSIX `sh` | they run `rc` by the user's decision; track Q brings toybox's `sh`, over `fork` ([design-programs.md](design-programs.md#the-posix-lite-personality)) | the user's, once track Q has brought `sh` |
| vi-style line editing in the command shell | emacs-style editing first, the user's choice | possible later |
| The network as files, `/net` | the network service's own interface comes first | with the network service's design |
| A FAT file server for removable media and exchange | booting and updates need none; the user wants it eventually ([design-storage.md](design-storage.md#removable-media-fat)) | after M13, with the first removable medium or exchange partition a board configuration names |
| A copy-on-write `fork` | the eager copy is the first `fork`, and copy-on-write is an optimisation | at gate GQ |
| A separate native root task that keeps configured domains alive across a restart of the system runtime | the system domain is the root task and its fault is a reset; the domain library behind one C interface keeps this a change behind a seam ([design.md](design.md#alternatives-considered)) | only if measured availability of the system domain asks for it |
| Hosting a sub-space under a user-level kernel, through vCPU user mode | Fiasco's vCPU interface can run a sub-space's code on a thread of its creator, as L4Linux does; erXos's subset leaves that mode out | when a use appears |
| An MSI translation service in the interrupt controller | QEMU `virt`'s MSI frame serves both accelerators ([design-platforms.md](design-platforms.md#msi-frames)) | with a board that needs it |
| Unmapping the kernel from user-mode page tables | needed only on cores that Arm lists as affected by rogue data cache loads | with each board port, from Arm's list of affected cores |
| The release process: who keeps the release signing key and how it is replaced; whether release builds offer a host link | erXos is a prototype and makes no releases | when erXos makes releases |
| Graphics, USB, audio | not needed for the thesis | not planned |
| x86-64 | out of scope | not planned |
