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

* **A working system first.** The first milestones build a **vertical
  slice** of the system on the modified Fiasco behind erXos's kernel
  interface: the system domain's ERTS as the root task, the live machine,
  domains over connections, the command shell with its programs as ports
  of their sessions, and immutable code with one data store. The stopgap
  carries only the part of the interface the slice needs, with ERTS
  adapted only as far as it must be. erXos's own kernel then boots the
  same slice and replaces the stopgap, and everything after the slice,
  the security closure included, lands on erXos's kernel alone
  ([design-kernel.md](design-kernel.md#the-current-implementation-the-modified-fiasco)).
* **A demo per milestone.** Every milestone ends with something a person
  can watch, and `make run` works at every commit.
* **Tests accumulate.** Each milestone adds transcript tests under TCG and
  HVF and keeps every earlier test passing. Exit criteria are tests, never
  inspection.
* **The conformance suite grows with the interface.** Every kernel call
  lands with tests of its contract, which run on the stopgap from M1 for
  the calls it carries and on erXos's kernel from its first boot; with the
  slice's own tests, they decide the replacement.
* **The oracle runs on a schedule.** M0 verifies the test runner with focused
  cases and controlled pass, failure, skip, timeout and interruption checks.
  The complete stock reference runs are recorded before ERTS port changes
  begin. From M3 on, OTP's `emulator`, `kernel`,
  `stdlib` and `compiler` suites run on erXos, in the system domain until
  M5 brings domains and in a test domain from then on, and are compared
  case by case with stock OTP 29.1.2 in the host's isolated Linux oracle
  ([design.md](design.md#testing-and-the-oracle)). A fast subset runs with
  `make check` on every change; the full suites at every major change (to
  the kernel or the stopgap, the scheduler, memory, the funnel and the
  connections' carrier, the adapter, the loader, or the build of OTP or
  musl) and at each milestone's exit. `make check-oracle` also runs musl's
  `libc-test`.
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
  kernel is the slice's; every difference is a bug in the replacement, a
  documented improvement with a test, or a bug in the stopgap recorded as
  such.
* **Checks before the code they police.** The generators, the drift check,
  the stack proof and each chokepoint check land before or with the first
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

The plan has three parts. The first, M0 to M6 with tracks H and S and
the first part of track P, builds the vertical slice on the stopgap. The
second, track K and M7, boots the same slice on erXos's kernel, which
then replaces the stopgap. The third, M8 to M14 with track Q and the rest
of tracks S and P, adds everything else on erXos's kernel alone.

| Milestone | Demo | New code (estimate) | Needs | Gate |
| --- | --- | --- | --- | --- |
| M0 The tree, the toolchain and the oracle | focused stock OTP 29.1.2 cases verify the offline Linux test runner; native Mac OTP supplies bootstrap tools; the frozen Fiasco set builds from the tree; every generated file regenerates unchanged | 4,000 lines of Ruby | | G0 |
| M1 The stopgap speaks erXos's interface | the modified Fiasco prints erXos's banner and starts the root task under TCG and HVF; in a partial boot the root task builds two hostile domains that attack the interface for ten minutes with threads pinned to every CPU; a stopped watchdog pet ends the machine with a crash record | 12,000 lines of C17, 2,000 of C++ glue | M0, G0 | G1 |
| M2 The execution contract holds | a native test domain and a hostile domain share four CPUs by grants; no wakeup is lost; a blocking call from an executor is refused | 4,000 lines of C17 | M1 | G2 |
| Track H Hosted mode | the runtime, with the domain library and connections between domains, runs as Mac processes under the sanitizers | 3,000 lines of C17 | M0 | |
| M3 The shell is the operating system | `1>` on the serial console, from ERTS in the system domain in user mode, started by the root task | 8,000 lines of C, 1,000 of Erlang | M2, track H | G3 |
| M4 The machine is an object | save in the editor on the Mac, run in the machine; follow a process to its source; one timeline of kernel and ERTS events; BeamAsm for ordinary domains | 10,000 lines of Erlang, 3,000 of Ruby, 2,000 of C | M3 | |
| M5 A wall around some processes | spawn into a sandbox domain with a link, crash it, get `{domain_down, D, crash}`; kill a domain under load and watch everything it held come back; a hostile runtime attacks a neighbour's funnel for ten minutes without effect; kill the system domain and read its crash record after the reset | 9,000 lines of C17, 6,000 of Erlang | M4 | G5 |
| Track S The command shell and toybox | `ps \| where 'memory > 10000000'` in a shell with rc's language, then `grep -r error /tmp/logs \| wc -l` through toybox's applets as ports of the session, and `within` confining a program to one grant | 6,000 lines of Erlang, 4,000 of C17 | M4 for the shell, M5 for programs, M7 for their job control | |
| Track P The POSIX-lite personality | a Unix program recompiled unchanged pipes, polls, spawns children and takes `SIGINT` | 10,000 to 15,000 lines of C | track S | GP |
| M6 Immutable code, lasting data | the shell runs toybox's applets from a verified EROFS image; a file under `/data` survives a power cut; one flipped byte of an image fails only the reads of its block | estimated in the subsystems' design documents | M5, track S, the first part of track P | G6 |
| Track K erXos's kernel | the pilot, then the kernel, booting the slice's boot image and passing the conformance suite | 25,000 to 40,000 lines of C17, of which the shared core exists; the pilot calibrates the figure | GK1 after M2; GK2 after M5 | GK1, GK2, GK3 |
| M7 The stopgap leaves | erXos's kernel boots the slice and runs every test and benchmark the slice ran on the stopgap | integration | track K, M6, track S, the first part of track P | GK3 |
| M8 Cooperation earns its place | the ladder from plain threads to full cooperation, measured on seven workloads, with each feature kept or dropped by its numbers | 4,000 lines of C17 and C | M7 | G8 |
| M9 A driver is an Erlang process | a driver process dies under load, its supervisor restarts it, and nobody notices | estimate: 3,000 lines of C17, 5,000 of Erlang | M7 | G9 |
| M10 Users without a container runtime | two users, two domains, one runs out of memory or CPU alone | 4,000 lines of Erlang | M8, M9 | |
| Track Q The second tier | toybox's `sh` runs a script with subshells, `vi` edits a file and `less` pages a log in a terminal session, and a dynamically linked program loads a library with `dlopen` | the programs' estimate in [design-programs.md](design-programs.md#performance), and the session's shared mappings, an estimated 3,000 lines of Erlang; the kernel's part is track K's | track P, M7 | GQ |
| M11 Security closure | a release build without the development banner, on erXos's kernel, with an Erlang driver behind an IOMMU window | hardening | M10 | |
| M12 Storage, networking, boards | a Raspberry Pi 4 boots erXos from its SD card, keeps its files through power cuts, and takes a system update whose trial survives a power cut | estimated in the subsystems' design documents | M11 | G12, GN |
| M13 erXos's F2FS | an installation brings erXos's F2FS, written in Erlang, to the Pi 4, whose files survive power cuts and a later update's failed trial and mount in Linux | estimated in its design document | M12 | G13 |
| M14 erXos's network stack | M12's sessions run over erXos's own TCP/IP stack, written in Erlang, on both boards | estimated in its design document, within GN's decision | M12 | G14 |

The order reaches a usable system first:

* The stopgap learns the part of erXos's interface that the slice needs,
  implementing its semantics inside Fiasco's kernel, so everything above
  it is built once.
* The execution contract is tested right after boot, with the smallest
  runtime and hostile programs, while the kernel side is small and before
  ERTS builds on it; the same milestone takes the first measurement of
  the dispatch models.
* The shell runs on ERTS with only the changes it cannot run without.
* The live machine follows at once, because it is the product's identity
  and the instrument every later milestone is debugged with.
* Then the unified process space over connections, with the hostile
  runtimes at the receiving funnel and the system domain's end as a reset;
  the command shell, whose programs spawn each other and talk over pipes;
  and immutable code with one practical data store. Together they are the
  vertical slice, and gate G6 measures what a domain costs, what a frame
  across a connection costs and how well domains are kept apart before
  anything more is built on it.
* erXos's kernel is written alongside from gate GK2 and boots the same
  slice; the conformance suite and the slice's own tests decide the
  switch, by parity over the slice, which is all the stopgap carries.
* Everything after the slice lands on erXos's kernel alone: the
  cooperation features, drivers and users, the second tier, the security
  closure, and then the boards, storage and networking.
* Storage, networking and the boards stand on littlefs and lwIP first;
  erXos's F2FS and erXos's network stack, both written in Erlang, then
  replace them, one at a time, each at parity. A prototype of the packet
  path is measured on QEMU and on the Pi 4 before the network stack is
  built, so its design knows what Erlang carries (gate GN).

**Effort.** The estimates are sizes of new code, derived from the design
documents and from comparable components; they order and scope the work
and are not dates. Agents write most of the code; the verification,
review and decisions around it set the pace. Gate GK1 measures that pace on
a real piece of the kernel and converts sizes into time for the rest of the
plan.

## First integration checkpoint

After M3, build the basic inspection path of M4 and the domain and
connection path of M5 together. This is the smallest coherent
demonstration of erXos:

* boot the root task and the system ERTS under TCG and HVF, with the
  trusted-code development banner;
* create one application domain from a pinned release through the domain
  library, give it one facet, and exchange a bounded request and reply
  over its connection to the system domain;
* inspect its pid, budget, grant, connections, exports and reported state
  through the same schema used by the console;
* exhaust or crash that domain and observe its end, `{domain_down, D,
  Info}` on its domain pid, its connection taken down and every charge
  back in its principal's budget, without losing the system shell;
* disconnect two introduced domains, observe `noconnection` on everything
  across their connection, introduce them again and complete another
  operation.

The checkpoint uses plain scheduling and the interpreter. Full tracing,
BeamAsm, host-watch loading, the command shell, POSIX programs and durable
storage are not prerequisites for it. They retain their target designs
and milestone exit criteria; this ordering does not mark M4 or M5 complete
or trim the architecture to the demonstration. The stopgap provides only
its documented guarantees, so this checkpoint admits trusted code alone.
The full M0 to M6 slice remains the replacement workload for erXos's
kernel.

## Simplification experiments

Experiments decide implementations behind the accepted seams. They do not
silently weaken authority, accounting or compatibility contracts. Every
result records the required host, accelerator, toolchain, workload and
baseline conditions; unknown or unsupported results stay explicit.

| Gate | When | Comparison and required evidence | Decision |
| --- | --- | --- | --- |
| E-D1 in hosted mode | hosted mode after M3, before the connections land under QEMU | `tools/erx bench xdomain-pingpong` and `xdomain-throughput` between two hosted domains at lane sizes of 16 KiB and 64 KiB, and a `gen_server:call` round trip, against loopback distribution on the host; round-trip distribution, throughput by frame and lane size, CPU per frame in each runtime | the first values of `lane` and the system manifest's `system_lane`, the producer's wait rule, and whether ERTS encodes straight into the lane, each confirmed or revised at G5 under HVF ([design-domains.md](design-domains.md#performance)) |
| GP, programs and pipes | track P, in hosted mode first and under HVF before the first part of track P is complete | a program's start from the session's `spawn` to its `main` (`tools/erx bench spawn`) against the budget of [design-programs.md](design-programs.md#performance); a `make`-shaped workload of many short children over pipes with a paused pager, and `tools/erx bench pipe` with one writer and with 256 writers; latency, throughput, memory per program and per pipe, and the session's Erlang work per request | the channel's and the data area's defaults, completion batching in the handler, whether the pipe server keeps one ring per write end ([design-pipes.md](design-pipes.md#the-ring)), and whether a program's start needs a cheaper path than one kernel call per object |

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
creation with a failure injected at each step and its undo; and the funnel's verdict table over
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
| Declaration model and generation checks | M0 | explicit ABI fragments with one qualified type/name namespace; complete-input validation, deterministic output inventory and drift checks for paths and bytes; typed layouts and assertions; status/errno/fault/signal mapping infrastructure; valid-input builders, boundary mutations and fuzz entry points alongside each parser; invalid-schema and stale/missing/orphaned-output tests |
| First generated service interface and startup descriptors | M3 | console/service operations generate C/Erlang clients, admission/dispatch and bounded replies with scope policy in the handler; source checks refuse bypasses; the checked manifest's packed descriptors supply boot order, devices, configured facets and watchdog liveness; no second compiled configuration table |
| Inspection and host-facing service bindings | M4 | `abi/inspection.txt` generates builders, C/Erlang/Ruby types/validators, path/field/status/unit tables and shell/host/`/proc` projections; host-exposed service operations generate Ruby clients; independent tests reject restricted fields, unknown keys and reply mismatches and preserve each status/reporter; generated docs and fuzz scaffolding land with the interfaces |
| Cross-domain service and protocol consumers | M5 and each later service | generated serving paths authenticate lane origin, check the live facet scope and bound input/output before callbacks; hostile tests exercise forged origins, stale handles and denied targets; the 9P profile keeps its independent standard oracle |
| Command catalogs | track S | release metadata generates names, help, required facets and output-field descriptors, checked against callbacks without running target code; tests preserve name conflicts/precedence and bind metadata to loaded code across replacement and publication failures; a catalog grants no authority |
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
| TLC setup and first update model | runner in M0; the small update model alongside M1 to M3, before extending the suite to M4 | `make check-tla`, separate from `make check`; jar version/hash and JVM setup; private run directories, deadlines, complete expectation roster, caching with an uncached mode and runner failure tests; the update model covers committed/spare slots, healthy trial and power loss, with targeted broken configurations and reachability witnesses; it does not wait for an update implementation |
| Host-link model and implementation mapping | M4, before accepting session handling | TLC checks session replacement, duplicate calls, expiry and credit; host traces check the actual pure core against an independent oracle; every invariant maps to a concrete check |
| Connection model and implementation mapping | M5, before connections run under QEMU | TLC checks peer death, ordered delivery, unmapping and object retirement, including distinct peer incarnations; host tests cover the lane and teardown cores and failure traces; weak-memory ordering stays with `herd7` and conformance tests |
| CBMC pilot | track K's capability-table and budget pilot after M2, before GK2 | check actual C arithmetic, allocation failure and retirement with explicit input and unwind bounds; detect seeded defects; report unsupported constructs, cost and assumptions; adopt further use only if it adds useful evidence at maintainable cost; existing GK1/GK2 tests remain required regardless |
| awklog manifest pilot | M3, alongside the Ruby manifest check | compare ownership, facet-target, boot-order and rescue-closure rules with an independent Ruby oracle over small configurations and seeded violations; preserve diagnostics and all manifest properties, with exact resource arithmetic in Ruby; adopt only if the rules simplify the check without duplicating policy |
| Update mechanism and implementation mapping | M12, before accepting the slot writer and update service | extend the initial model to every durable boundary, torn record, reset count, firmware trial outcome and failure in the storage contract; run TLC uncached; replay counterexamples as host regressions and QEMU crash tests; record the board/firmware assumptions and actual conformance evidence |

A selected tool missing from a requested gate fails with a diagnostic;
no gate silently skips it. Incomplete searches, timeouts and unsupported
results remain explicit and fail acceptance. The two pilots decide
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
runs a focused stock case and stores its result; `tools/erx build fiasco` builds the frozen Fiasco set
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
  not an M0 exit condition. Native macOS builds supply bootstrap tools and separate
  native performance baselines; they do not stand in for Linux suite results.
* The QEMU harness: QEMU `virt` as
  [design-platforms.md](design-platforms.md#qemu-virt) configures it under
  both accelerators, `-no-reboot`, serial output in logs, named lines
  awaited under named deadlines, transcripts compared with expected ones.
* The generators and the drift check: `abi/erx_abi.txt`, its explicit
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
  C17 validator and its fuzz target. Production `tools/erx pack` refuses
  output until the real startup planner is available, as specified below.
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
`Manifest.admit` and production packing remain blocked on the real
initial-root feasibility/charge plan, even when no child is configured.
The root image's checked private-memory lower bound is still enforced;
a sufficient declared baseline alone is not a startup proof. The separate
M0 guest demo boots the frozen Fiasco set to its banner and does not claim
to execute erXos's root interface.

Independent populated binary fixtures exercise every manifest record and
the C, Erlang and Ruby structural readers without claiming policy
admission. M1 supplies the production initial-root bootstrap/charge plan
and `erx_dom_plan_create` for both host admission checks and runtime
creation. Any unavailable required sizing, planning or service consumer
fails as unsupported. There is no temporary planner, weakened admission
path or reduced target manifest format.

**Exit criteria.** `make check` passes offline after `make fetch`; the
oracle records a focused Linux stock case and correctly reports controlled
passes, failures, skips, timeouts and interrupted/incomplete runs. It proves
loopback peer operation and absence of external networking, and removes
its container including daemonized test children on success or cancellation;
the stopgap boots to Fiasco's banner under TCG and HVF in the harness; a
build twice from clean gives identical structural `ERXPACK` fixtures, with
startup and policy admission explicitly unsupported; the fuzz target of the
boot-image validator runs its budget clean.
The TLC runner's tests pass, including targeted expected failures, wrong
properties, parser errors, incomplete runs, cache invalidation and empty
filters; the separate `check-tla` entry point reports missing tools as an
error and performs no network access. Generation rejects invalid schemas
before publishing output and fails drift checks for changed, missing and
orphaned files. Independent fixtures check generated parsers and mappings.

**Gate G0.** The import: the licence scan and link closure of the Fiasco
set, which name the GPL-headed files the stopgap keeps
([design.md](design.md#dependencies)); since `kobject_rpc.h`, which every
build includes, is one of them, any distribution outside the project, in
source or binary form, waits for erXos's kernel, as CLAUDE.md's rule for
stopgaps requires. `lld` installed.

## M1: The stopgap speaks erXos's interface

**Goal.** The modified Fiasco implements the part of erXos's kernel
interface that the slice needs, with its semantics inside Fiasco's
kernel, and `liberx`'s `fiasco` backend is the only code above it that
knows Fiasco; the kernel starts one task, the root task, and watches it.

**Demo.** The boot image boots through `bootstrap`, which validates it with
erXos's validator; the kernel prints erXos's banner, `development build:
trusted code only`, and starts the root task with the root capabilities;
booted with a development system manifest that names two hostile programs
as its partial boot, `liberx`'s root-task entry builds two native domains
through the domain library instead of starting ERTS, each with threads
pinned to every online CPU; in each of TCG and HVF with one and four CPUs,
they attack every call for ten minutes with malformed arguments, stale and
wrong-rights capabilities, faults and floods (but no stream of thread
kills, whose starvation of a CPU is a residual of the stopgap that
erXos's kernel bounds and its own milestone tests;
[design-stopgap-scheduling.md](design-stopgap-scheduling.md#security)),
each domain reporting
per-CPU progress counters on the console; the harness checks that every
CPU of every domain makes progress through the whole run and that the root
task keeps petting the watchdog, since nothing else in a partial boot holds
`POWER`; a
boot whose pet is stopped through a test-build hook ends the machine at
the deadline with a crash record on the console that names the watchdog.

**Scope.** In the fork, with the decisions in C17 cores shared with
erXos's future kernel, and no more of the interface than the slice uses,
as the stopgap's scope table lists
([design-kernel.md](design-kernel.md#the-current-implementation-the-modified-fiasco)):

* capabilities with generations and per-type rights in Fiasco's flat
  object space, with copies, closes, `erx_cap_pass` in its creator's case
  and deletion, which frees an object after an RCU grace period, as
  Fiasco does; budgets as space banks, whose deletion deletes every
  object charged to them; capability transfer at an IPC rendezvous lands
  in M5, with M1's IPC designed to add it without reshaping the rendezvous;
* spaces, each with its parent, fault gate and label fixed at creation,
  threads (executors and workers), private and shared memory objects and
  the physical objects the kernel makes: the boot image, its slices
  (`erx_image_slice`), the time page and groups' shared areas; ceilings
  and reserves, W^X, faults to fault gates,
  `erx_space_stop` and exit records that arrive only once no thread of the
  space can run (K18), a stopped thread finishing the call it is in, or
  waking from its wait, before it dies; sealed
  paged objects, contiguous objects and physical objects created from device
  resources arrive with their first consumers;
* IPC gates bound to one thread each, with labels and timeouts, a server
  running at its own urgency and on its own group's grant from its first
  instruction; IRQ
  objects bound to threads, or to groups with labels and listed on the
  groups' ready lists, passing with `TRIGGER` and never with `BIND`, so a
  holder can ring one and never take its deliveries; umtx; the early
  console; the time page; entropy; `erx_machine_end`;
* the root task: the first space without parent or fault gate, the root
  capabilities at the ABI file's well-known slots, the boot information
  page flagged `ERX_BOOT_ROOT`, and the device-secret page with the status
  `no_key` ([design-kernel.md](design-kernel.md#the-root-task));
* the watchdog: `erx_watchdog_pet` on the platform object, needing
  `POWER`, armed when the root task starts under `erx.watchdog`'s period,
  deadline and boot deadline, its deadline checked at Fiasco's tick, and
  the crash record, written to the early console and followed by the end
  of the machine through the firmware, for a missed deadline, a fault of
  the root task and its halt outside `erx_machine_end`
  ([design-kernel.md](design-kernel.md#the-watchdog));
* groups in configuration C0: urgency levels, round robin within a level,
  park and wake with epochs, the executor rule; the quota pool's C17 core
  built and tested on the host, with target enforcement in configuration C1
  ([design-scheduler.md](design-scheduler.md#park-and-wake)).

Above the fork: `liberx` with its generated calls and its `fiasco` backend;
`liberx`'s root-task entry, `erx_root_main`, which reads the system
manifest through its generated C reader and, for a development manifest's
partial boot, builds the programs the manifest names as domains through
the domain library ([design-system.md](design-system.md#boot)); the
domain library's production `erx_dom_plan_create` core for native domains,
built for the host as the packer's property-12 checker as well as for
the runtime, validated whole and
undone step by step
([design-system.md](design-system.md#the-domain-library)); the
production initial-root bootstrap plan and backend/ABI-bound charge
evidence, which make full boot admission possible rather than substituting
source-declared costs; the
conformance suite for every call in scope; the chokepoint checks that confine
kernel calls to `liberx` and Fiasco headers to its `fiasco` backend; the
stack proof and chokepoint checks over the C17 cores; the fuzz targets of
the crash record's reader and of the manifest's C reader.

**Exit criteria.** The conformance suite passes under TCG and HVF on one
and four CPUs; in each of those four configurations, two hostile native
domains run for ten minutes with threads pinned to every online CPU, each
reports per-CPU progress counters on the console, and the harness checks
that every CPU of every domain makes progress through the whole run and
that the root task keeps petting the watchdog, with no kernel or root-task
fault; the park protocol's exhaustive host model
passes (S2); every call that may wait refuses an executor, umtx waits on
private memory excepted (S3); a space stopped while its threads run, fault
and call on every CPU posts exactly one exit record, after its last thread
has finished its call or left its wait and died (K18); a server whose
group's ceiling is 15 runs at most at 15 while serving a caller at 40, and
runs on its own group's grant from its first instruction (S5); the
host test of
`erx_tlb_plan` finds every removal invalidating what it made stale, each
cleared table entry over its span in the walk caches and with the IOMMU's
every-level form (K9); a pet from a thread without `POWER` is refused, and
a boot that never pets, a pet stopped through the test-build hook, a fault
of the root task and its halt each end the machine with a crash record
whose cause names them, which the harness reads from the serial log (K31);
the domain library's creation plan passes its host tests with a failure
injected at each step and every object released; the call decoder's, the
crash record's and the manifest's C reader's fuzz targets run their
budgets clean; the park lock and the quota pool's host core pass their
ThreadSanitizer runs; the C17 cores pass their host
tests under ASan and UBSan.

**Gate G1.** Measures, under HVF and TCG: the null call, an IPC round trip
through a gate within and across spaces, park and wake on one CPU and
across CPUs, deadline-to-resume latency (`tools/erx bench timer`, the
return from a deadline wait against its deadline, since M1 has no device
line to program), boot time to the root task's start, and
`tools/erx bench stop`, the stop of a space with threads in calls and
waits on every CPU. Decides: the timer slack and default time slice;
whether the stopgap's 1 ms tick accounting suffices until M7.

## M2: The execution contract holds

**Goal.** The runtime contract works with the smallest runtime and under
attack, before ERTS builds on it.

**Demo.** Booted with a partial boot, the root task builds two native
domains through the domain library: one runs the contract test program,
four executors that park and wake over rings in shared memory and pass a
thousand messages a second among a thousand tasks of the program's own;
the other is hostile, spinning on every executor, signalling, parking
with stale epochs and calling blocking operations from executors. The
test domain keeps its grant; no wakeup is lost; every blocking call from
an executor returns `ERX_EWOULDBLOCK`.

**Scope.** Groups in configuration C1: grants with quota, period, cpuset
and capacity, the group tree, charging and throttling at Fiasco's tick,
refill cohorts, the status area's capacity and usage,
`erx_group_configure` and its replacement of a grant, the deletion of
groups; the contract test program in `liberx`'s conformance suite, which
every later native test domain builds on; the dispatch-model
microbenchmarks.

**Exit criteria.** A group capped at 30% stays within its quota per period
to one tick per CPU (E-S7 on the stopgap); the test domain's executors
resume exactly where they were preempted (S1, checked by a test that
preempts at every instruction of a loop in deterministic mode); the storm
test of the park protocol passes on four CPUs under TCG and HVF; a group
of zero quota with 1,000 throttled threads costs each CPU one timer expiry
and one failed draw per period; a space whose group's quota is zero, or
spent, still posts its exit record once its threads have finished their
calls (K18); the refill and grant-replacement host tests pass.

**Gate G2.** Measures the early form of E-S2: a switch between two kernel
threads of one space and of two spaces, an IPC round trip through a gate,
and park and wake, under HVF; and E-S4's FIFO wake latency. The stopgap's
measured costs (an IPC of 51 to 89 ns, inferred from an emulated counter)
set the floor that a runtime's own switching must beat by an order of
magnitude; the full comparison with ERTS's processes is G5's. Decides:
whether park, wake and the FIFO wake latency meet E-S4's hypotheses, so
that the two-level model proceeds onto ERTS; if they do not, the design
returns to the user with the numbers before ERTS builds on the contract.

## Track H: Hosted mode

Before modifying ERTS for the port, record the complete stock OTP 29.1.2
`emulator`, `kernel` and `stdlib` reference runs in interpreter and JIT modes.
Keep case identities, outcomes, skips, environment details and incomplete
records explicit. These reference runs are required for the ERTS comparison;
they do not block the earlier kernel milestones.

`liberx`'s hosted backend implements the kernel interface inside a macOS
process: spaces are the process, threads are pthreads, memory objects are
`mmap`ped regions, umtx waits are `os_sync_wait_on_address`, and groups and
parking keep the epoch protocol
([design-runtime.md](design-runtime.md#liberx)). From M3 on, ERTS's port
runs hosted first, under ASan, UBSan and TSan, and `lldb`; from M5 on,
several domains run as Mac processes with their lanes in shared regions,
the domain library driving the hosted interface, so connections, the
funnel and the domain library's plans are measured and sanitized before
they run under QEMU. QEMU remains authoritative.

## M3: The shell is the operating system

**Goal.** ERTS runs as the system domain in user mode on the contract,
started by the root task, with only the changes it cannot run without.

**Prerequisite.** The complete stock reference runs described in
[hosted mode](#track-h-hosted-mode) are available before the ERTS port changes.

**Demo.** `1>` on the serial console; the shell evaluates, line editing
and history work, and `erlang:processes()` lists the system domain's
processes; an idle machine shows every executor parked.

**Scope.** The root-task entry's full boot, which builds the system
domain's memory, threads and group from the system manifest and starts
ERTS on a system release whose manifest names no other domain
([design-system.md](design-system.md#the-root-task)); the system manifest,
the one file the build packs into the boot image to configure the system,
with its Erlang reader, `erx_manifest`, and the fuzz target of that
reader, and the Ruby check that proves properties over the manifest at
build time and fails the build on a violation (over device holders and
their confinement, the servers that facets name, the holder of
configuration space, the root task's image carrying no `ERX_IMAGE_JIT`,
and the sums of budgets and grants), each property with a seeded
violation ([design-system.md](design-system.md#the-manifest)); the awklog
manifest pilot decides its relational implementation while the Ruby check
remains complete ([Verification work](#verification-work)); generated
console/service clients, admission/dispatch and reply checks, plus startup
descriptors from the packed manifest ([Generation work](#generation-work));
the
interpreter image, the runtime image that the system domain, the command
domains and deterministic mode run; the adapter's first five changes
(executors and workers, sleep over `erx_park`, wake over
`erx_executor_wake`, no busy waiting, the safe point with capacity), with
no cooperation flag enabled
([design-runtime.md](design-runtime.md#scheduling)), among the 27 edits
in 22 files that ERTS's own files take in all
([design-runtime.md](design-runtime.md#the-edits-outside-syserxos));
threads, memory, time, files (release file system and `/tmp`) and crash
handling in `sys/erxos`; the watchdog process, `erx_watchdog`, petting
from the system release; musl behind `liberx`; the console service and
the console's driver, an Erlang process in the system domain over the
device NIF, with no console NIF
([design-runtime.md](design-runtime.md#the-console-and-standard-io)), on
the UART that the system manifest names by its device-tree path, which
the device service checks against `/chosen/stdout-path` at boot, refusing
a manifest whose console differs
([design-system.md](design-system.md#devices)); the build behind
`tools/erx build runtime`; `prim_file`'s path resolution with its fuzz
target.

**Exit criteria.** The fast oracle subset passes in the system domain and
the full suites at the milestone's exit, every difference documented;
musl's `libc-test` runs in a test domain with every failure a bug, a
documented difference with a test, or an upstream bug recorded as such; a
deterministic-mode boot to the shell gives a byte-identical transcript; an
ERTS fatal error in the system domain, `erlang:halt/1` from a system
process and a stopped watchdog pet each end the machine with a crash
record on the console whose cause names them, and the machine ends as
`erx.panic` says; the manifest check fails the build on a seeded
violation of each of its properties; a manifest whose console differs from
`/chosen/stdout-path` is refused at boot; the interpreter image links no
BeamAsm, asmjit or libc++ symbol, and the boot image's root entry carries
no `ERX_IMAGE_JIT`; the fuzz target of the Erlang manifest reader runs
its budget clean.

**Gate G3.** Measures: W1 of E-S1 (same-domain ping-pong and ring, spawn,
switch) against stock OTP 29.1.2 on the host; footprint; boot time to the
shell and to the first pet; E-S10, refusals across OTP's suites. Decides:
default table sizes; whether the boot path needs work; the baseline every
later change is measured against; which NIFs move to dirty schedulers.

## M4: The machine is an object

**Goal.** The live machine, which every later milestone is debugged with,
and BeamAsm for ordinary domains.

**Demo.** On the Mac, `erx watch` recompiles a changed module and hot-loads
it into the running system domain through the install facet; `erx:i()`
shows CPUs, threads, groups and processes with each value's reporter;
`erx:source(Pid)` shows the line a process is executing; `erx:trace` shows
kernel dispatches and ERTS scheduling on one timeline.

**Scope.** The generated inspection schema and its C/Erlang/Ruby bindings,
status/reporter-preserving renderers and `/proc` projections; generated
Ruby clients for host-exposed service operations, with their bounded
request/reply checks; the inspector, the tracer, the host link with its
sessions and deframer (and their fuzz targets), on the UART that the system manifest
names by its device-tree path, the code service with the install arena
and `ERX_BOOT_INSTALLED_ONLY` ([design-live.md](design-live.md),
[design-runtime.md](design-runtime.md#code-in-the-system-domain)); the
code store in memory, with loads by hash, checked by the SHA-256
primitive ([design-runtime.md](design-runtime.md#per-byte-primitives)),
manifests, history and the missing-blob exchange
([design-live.md](design-live.md#the-code-store)); the system domain's
namespace, `erx_ns_resolve` in `prim_file` with its fuzz target, the file
protocol, which is 9P2000.L, with its codec and fuzz target, `erx_fs` and
`/proc`, with the previous boot's crash record under `[kernel, crash]`
where the platform keeps one ([design-files.md](design-files.md)); the
host link's files stream, stream 4, which `tools/erx files` relays to a
Unix socket on the Mac so that any 9P2000.L client there mounts the
machine's `proc` tree, and the host-tree domain, which holds QEMU's
virtio-9p device and serves the Mac's tree at `/host`, from M5, whose
domain service creates it
([design-live.md](design-live.md#files-between-the-host-and-the-machine));
the Unicode-aware escapers with their table generated from OTP's Unicode
data and a fuzz target each
([design-live.md](design-live.md#text-on-terminals)); the `shell_default`
shortcuts and their collision test; BeamAsm in the BeamAsm image, the
runtime image for ordinary domains, built beside the interpreter image,
with JIT objects mapped twice in spaces allowed JIT objects, user-mode
cache maintenance, the code barrier, libc++ without exceptions, and the
repaired error paths ([design-runtime.md](design-runtime.md#beamasm)); the
system domain runs the interpreter image and holds no JIT object. Until
M5 brings the domain service, BeamAsm runs in a test domain that a
partial boot builds. The system-only boot remains an isolated runtime
probe. Basic
inspection also participates in the first integration checkpoint's full
boot with one application domain over its connection, before the rest of
M4 and M5 is complete.

**Exit criteria.** The host-link tests (session replacement, at-most-once
calls, credit, the 1,025th facet) pass; a module reloaded in a loop on four
CPUs under BeamAsm never runs stale code; a page-table walk after every
test finds no writable and executable mapping; a blob one bit off its hash
never loads; every character class of the escapers has its test at each
terminal writer; `file:read_file("/proc/processes/4.N.S/status")` in the
system shell, where 4 is the system domain's id, returns every status the
inspector can report; a file read through `tools/erx files` equals its
source on the machine; the fuzz targets of the deframer, `erx_ns_resolve`,
the 9P2000.L codec and each escaper run their budgets clean; the oracle's
full suites pass on the interpreter image in the system domain, and on the
BeamAsm image at M5, when the domain service can start a BeamAsm domain.

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

**Scope.**

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
  name as stock keys it, the `erx_connections` application and the
  `erx_lane` linked-in driver as the carrier, the busy-port rule when a
  lane is full, the export table with its three writers (`erx:export/3`
  narrowing only), unguessable references, and the receive boost's
  plumbing (urgency in records); `erx_etf` in `liberx`
  ([design-runtime.md](design-runtime.md#connections-in-erts),
  [design-domains.md](design-domains.md#exports)).
* **The domain library and the system services**: the domain library's
  full creation plan with undo, its fault thread and gate, end
  classification and `{domain_down, D, Info}`, connection down with its
  deadline, and the ordered end of the machine; the domain service, which
  creates the domains the system manifest configures and makes their
  introductions, domain pids, facets, code facets,
  `erx_domain:introduce/1,2`, with `erlang:disconnect_node/1` taking a
  connection down; namespaces
  built for every domain, with facets mounted as file servers and
  `erx_file_remote` ([design-files.md](design-files.md)); identifiers
  checked by `erx_ident`
  ([design-system.md](design-system.md#identifiers)); domain ids
  allocated by the domain service, never reused within a boot
  ([design-system.md](design-system.md#the-domain-library),
  [design-system.md](design-system.md#creating-a-domain)).
* **The kernel interface sub-spaces and programs need**, in the stopgap
  with its conformance tests: capability passing at a rendezvous and by
  `erx_cap_pass`, deleted memory whose mappings fault, `erx_mem_copy`, the
  emptying of a stopped space's table, space parents
  with stop propagation, sub-space creation by a domain allowed `SPACES`,
  and vCPU upcalls
  ([design-kernel.md](design-kernel.md#passing-capabilities),
  [design-kernel.md](design-kernel.md#closing-and-deleting),
  [design-kernel.md](design-kernel.md#creating-spaces),
  [design-kernel.md](design-kernel.md#vcpu-upcalls)), with the pass,
  deletion, stop and upcall cores explored on the host, so the slice's
  interface is complete at gate GK2, and what the stopgap leaves out
  follows on erXos's kernel alone ([Track K](#track-k-erxoss-kernel)).
* **Tests**: the funnel's fuzz target and its differential test against
  `binary_to_term/1`; the fuzz targets of the lane reader, `erx_etf`, the
  system domain's safe decode and the facets' generated admission; the
  hostile-runtime suite at the receiving funnel of
  [design-domains.md](design-domains.md#verification-and-testing); the
  root task's end tests of
  [design-system.md](design-system.md#verification-and-testing).

**Exit criteria.** The two-node differential scenario suite passes, every
difference in the compatibility table; the oracle's full suites pass on
the BeamAsm image in an ordinary domain that the domain service starts,
every difference documented; the invariants of
[design-domains.md](design-domains.md#invariants) have their tests; the
exhaustive models of one lane, of one connection whose peer ends and of
cross-domain links among three domains pass, progress included; the soak
of a million cross-domain calls from short-lived processes and from a
long-lived one whose calls time out passes with the callee's export table
at its live correspondents; the wake handshakes' litmus tests pass under
herd7, with and without their fences, and the lane's reader under TSan
with a writer rewriting its pages; a malformed frame ends the connection
from the receiver's side and the peer sees `noconnection` on everything
across it, in order with what the target sent before (D9); the system
domain killed under load, `erlang:halt/1` from a system process and a
stopped watchdog pet each leave a crash record on the console naming its
cause, every domain stopped and the machine ended as `erx.panic` says;
the hostile runtimes run ten minutes without affecting their neighbours'
memory, messages and liveness, each flooder blocking on its own lane and
the system domain on its own grant; F1, F2 and F5 have their tests, a
grant derived on a subtree reaching nothing above it whatever its client
sends; K21 and K25 hold across domains, and K26 in the stopgap's form, in
which a deleted object becomes unreachable as its slots empty
([design-kernel.md](design-kernel.md#the-current-implementation-the-modified-fiasco)),
with its container test, a map racing the destroy of its space, passing on
the stopgap, a deleted memory object faulting in every space that mapped
it, a peer that ignores `connection_down` faulting after the deadline and
nowhere before, and no server or driver ever mapping memory a client can
delete; a domain's sub-spaces stop with it and report their ends before
it (K27); the vCPU conformance tests pass, interrupting a worker that
computes, one that waits on a umtx word and one that waits for a reply,
and checking that a message to an armed thread with events enabled enters
no upcall and that a resume over a cleared pending flag still takes the
queued event; a domain the system manifest names reads a file of the
host's tree under `/host` through the host-tree domain, whose bridge
fails a reply that fails the codec with `eio` and leaves `/host`
mounted.

**Gate G5.** Measures E-D1 to E-D4, with
`tools/erx bench xdomain-pingpong`, `xdomain-throughput`, `xdomain-stall`
and `domain-lifecycle`, and the full form of E-S2 with ERTS processes in
one domain and in two domains over a connection against kernel threads in
one and two spaces. It also measures, in an ordinary domain, BeamAsm's
speedup over the interpreter on OTP's benchmarks and on the oracle's
suites, the footprint of a domain in each flavour and the time to
translate a release when the domain starts. Decides: the defaults of
`lane` and the manifest's `system_lane`, the producer's wait rule and
whether ERTS encodes straight into the lane; the funnel's allowance per
step; the death path's batching and the manifest's `system_queue`; the
busy limit and the facets' `max_request` and heap limits
([design-domains.md](design-domains.md#performance)); whether a trigger of
the ahead-of-time roster fires
([design-runtime.md](design-runtime.md#running-erlang-code-the-options));
and confirms or overturns the absence of any kernel object per lightweight
process.

## Track S: The command shell and toybox

The release command catalog is generated from module metadata and the
image's program list: names, help, required facets and declared output
fields, with callback and live-load publication checks
([Generation work](#generation-work)).

**Goal.** A command shell with rc's language in every session, and Unix
commands from toybox as ports of the session, sharing one command
namespace with Erlang commands ([design-shell.md](design-shell.md),
[design-programs.md](design-programs.md)).

**Demo.** In a console session, `ps | where 'memory > 10000000' | sort -k
reductions` filters records, keeping each value's status;
`grep -r error /tmp/logs | wc -l` runs two toybox applets in sub-spaces
of the session over a pipe, and `ps` lists them under the session as its
process table; `within /tmp/logs -- grep -r error /tmp/logs` reaches
nothing else; `Ctrl-Z`, `bg`, `fg` and `kill %1` move and end a job of
Erlang commands, and of programs once M7 has brought erXos's kernel's
pauses.

**Scope.** It starts after M4 with the shell itself, continues after M5
with programs, which belong to the slice, and after M7 with their job
control:

* the shell in Erlang: tokenizer, parser, evaluator, the interactive
  layer on `edlin`, job control, `erx_cmd` and the first Erlang commands,
  and the parser's fuzz target; plan9port's rc built from its pinned
  source as the oracle, with the corpus from `test.rc`, the parser checks
  and `trip.rc`;
* programs as ports of the session, over the sub-spaces M5 brings: the
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
  relay; the session's pipe server, `erx_pipe_srv`, which makes every ring
  and every doorbell and installs every end, with the exploration of its
  pipe core, and the pipe NIF ([design-pipes.md](design-pipes.md));
* the job control of programs through `erx_space_pause` and
  `erx_space_resume` on the program's image space, after M7, since only
  erXos's kernel pauses a space; before it, `Ctrl-Z` stops a job's Erlang
  commands and the shell names the programs that run on
  ([design-kernel.md](design-kernel.md#the-current-implementation-the-modified-fiasco));
* toybox 0.8.15 and `wak` imported as erXos's code and built applet by
  applet, each with toybox's own tests in a test domain.

**Exit criteria.** The shell's corpus agrees with plan9port's rc, every
difference classified and pinned by a test; toybox's tests pass for every
applet built, or each failure is classified; a pipe's end of stream
arrives only after its last writer goes and every byte written has been
read, a writer that faults included, and a program's end reaches its
port's owner as `{exit_status, N}` after its last bytes; a pipe with a
paused reader and sixty-four writers still spawns its sixty-fifth, which
blocks on its write, never on its spawn; job control pauses, resumes and
ends jobs of Erlang commands three generations deep, and from M7 jobs of
programs too; every class of the terminal escapes reaches the console
from a program's output escaped (V1); a narrowed program that tries every
command name reaches nothing outside its grants, and a program holds no
grant's pid and reaches nothing but its channel and the memory its
session mapped (SH1 of [design-shell.md](design-shell.md#invariants), P2
of [design-programs.md](design-programs.md#invariants)); passed files
share their offsets; the parser, `where`'s predicates, the startup
message and the channel protocol run their fuzz budgets clean.

## Track P: The POSIX-lite personality

**Goal.** Unix programs recompiled without porting
([design-programs.md](design-programs.md#the-posix-lite-personality)).

**Demo.** A Unix program recompiled unchanged against erXos's musl runs
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
over the vCPU upcalls M5 brings, triggered by the session's port driver
([design-programs.md](design-programs.md#signals-in-liberx)), with
`erx_sig_step` explored on the host; the generated `errno`, signal and fault
tables; `erx_exec` and `erx_elf_plan` with its fuzz target, and `rx` grants
with the `exec` open; `rc` in program mode, and `system` and `popen` over
it; the Open POSIX Test Suite as an external test tool in a test domain.
Its first part, descriptors with `dup` and `fcntl`, `pipe`, `posix_spawn`
with inherited descriptors and file actions, `wait` and `kill`, and
`erx_exec` with `rx` grants, belongs to the slice and comes before M7;
the rest may land on either side of the switch.

**Exit criteria.** musl's `libc-test` and the Open POSIX Test Suite pass,
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
hosted mode and then under HVF. Decides the channel's and the data area's
defaults, the handler's batching, whether the pipe server keeps one ring
per write end, and whether a program's start needs a cheaper path than
one kernel call per object.

## M6: Immutable code, lasting data

**Goal.** Executables and the system's files come from immutable images
checked block by block, and one practical store keeps data across power
cuts, so the slice is a system a person can use; gate G6 then measures
the slice before anything more is built on it.

**Demo.** A QEMU disk image holds a slot with the release's EROFS images
and a data partition. Booted from it, the shell runs toybox's applets from
the slot's EROFS image; a file written and synced under `/data` survives
the guest's power cut and the next boot; and one byte flipped in the
EROFS image fails the reads of its block with `eio` while every other file
reads on.

**Scope.**

* **A block device.** The virtio-mmio block driver, an Erlang process
  under a supervisor in the storage domain, over the device NIF
  `erx_device` in its first form, on which M3's console driver already
  runs: register reads and writes by name through the generated
  accessors, a buffer pool in a DMA-mapped memory object, descriptors
  posted and completed, and the line's IRQ object bound to the domain's
  group and delivered to the driver process through
  the poll backend ([design-runtime.md](design-runtime.md#the-device-nif),
  [design-system.md](design-system.md#drivers)); the driver parses the
  device's descriptors in Erlang; ordinary interrupts and unconfined DMA,
  the stopgap's driver profile, which M9 replaces with virtio-pci behind
  the IOMMU and M11 refuses unless configured; the part of the device
  service that gives the storage domain its device
  ([design-system.md](design-system.md#devices)); partition windows in the
  block service, with the partition table, its two extended boot records
  included, and its fuzz target
  ([design-storage.md](design-storage.md#data-model)).
* **Immutable code and files.** The block client over the storage
  domain's connection, the hash-checking reader with dm-verity's tree
  format, and CRC-32C among the per-byte primitives, each with its fuzz
  target ([design-runtime.md](design-runtime.md#per-byte-primitives));
  read-only images in the EROFS format, one per release: the EROFS reader
  in Erlang, preloaded in both runtime images, with its fuzz target;
  upstream's `mkfs.erofs` as the packer's host tool, the packer's hash
  trees, and the packer's disk image for QEMU, laid out by the ABI file's
  medium layout; `veritysetup`, Linux's EROFS driver and `fsck.erofs` as
  the oracle in a Linux guest; and executables run from the images through
  the sealed file objects a program's session maps
  ([design-programs.md](design-programs.md#what-a-program-can-start)).
* **One practical data store.** littlefs as the stopgap read-write file
  system, a sub-space port of the storage domain behind `erx_fs`, holding
  nothing but its channel and data area, with a fuzz target for its images,
  on the data partition
  ([design-storage.md](design-storage.md#read-write-storage)).
* **Booting from the disk image.** The QEMU harness's normal boot, without
  trials: it plays the firmware, reads the record from the disk image with
  its slot parser, which has its fuzz target, boots the slot the record
  names and writes the boot value into `/chosen`, from which the stopgap
  builds the machine page, so the device service grants the slot's EROFS
  windows
  ([design-platforms.md](design-platforms.md#slots-and-the-boot-selection-record));
  the harness's trials follow with M12.

**Exit criteria.** Every EROFS image the packer writes passes
`veritysetup` and mounts in the Linux guest with the files the reader
sees, and passes upstream's `fsck.erofs`; a block that fails its hash
fails only the reads that touch it; a file synced under `/data` survives
a power cut at every step of a scripted write load, under TCG and HVF; a
storage domain killed under load restarts with no acknowledged write
lost, and so does the block driver process alone, its supervisor
resetting the device; a crash injected into littlefs mid-write ends its
sub-space port, whose owner restarts it and remounts, with no acknowledged
write lost; the build check that only the driver's modules reference the
device NIF passes, with its seeded violation; the partition-table parser,
the EROFS reader, littlefs's images, the hash-checking reader and the
per-byte primitives run their fuzz budgets clean.

**Gate G6.** Measures the slice, under HVF and TCG apart: the memory of an
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
process and `tools/erx bench blk`. Decides whether the slice meets the
design's budgets, among them a minimal ERTS domain of about 10 MB and,
under HVF, a round trip of 3 us with executors busy and 10 us with them
parked, so that erXos's kernel boots the slice as designed, and confirms
or revises G5's lane defaults and the facets' limits; where a number
misses its budget, the design returns to the user with the numbers before
erXos's kernel takes the slice over.

## Track K: erXos's kernel

**Goal.** erXos's own C17 kernel, implementing first the interface the
stopgap implements and then the rest of the interface, from
[design-kernel.md](design-kernel.md).

* **The pilot**, from gate GK1 after M2: the capability table and budgets,
  written from the design document with their host tests and fuzz targets,
  and timed. The focused CBMC pilot checks its actual C cores, with the
  adoption criteria in [Verification work](#verification-work). The kernel
  pilot calibrates how long an agent takes from design to a
  reviewed, tested subsystem, which the plan then uses for the rest of the
  kernel.
* **The kernel**, from gate GK2, once M5 has completed the slice's
  interface and its conformance suite and benchmark baselines exist:
  Fiasco's process model with a kernel stack per thread and helping locks,
  the rest of the objects, memory windows in place of a copy funnel (no
  call takes a user address, and the kernel reads and writes the bytes a
  window names only through `erx_window_read` and `erx_window_write`),
  the shared C17 cores, the root task and the watchdog with the crash
  record in the layout the ABI file gives, the stack proof over every
  thread's kernel stack and every chokepoint check, booting the slice's
  boot image. Each mechanism lands with its conformance and hostile
  tests, and `tools/erx bench` measures its paths, the existence lock's
  contention and `tools/erx bench stop` among them.
* **The switch**, at gate GK3: the conformance suite, the slice's
  transcript tests, the oracle and the benchmarks run on both kernels,
  differentially ([M7](#m7-the-stopgap-leaves)). The stopgap carries only
  the slice's part of the interface, so the switch waits for nothing beyond
  the slice.
* **After the switch** the interface grows on erXos's kernel alone, each
  increment with its conformance and hostile tests: pauses, in their named
  states, for the job control of programs (track S), with their latency in
  `tools/erx bench pause`; the cooperation features of configuration C2
  (M8); the device interface, a PCIe bridge's windows, DMA windows, the
  IOMMU and MSI IRQ objects (M9); copy-on-write children, copies of
  spaces by a sub-space's creator, and store tracking with
  `erx_mem_dirty`, by hardware dirty-state management where the CPU has
  it and by write-protect faults elsewhere (track Q); and the machine
  lease of a trial boot, the board's hardware watchdog reloaded from the
  kernel's timer, the crash region and the device-secret key read (M12).
  The security closure, M11, is the release gate for all of it.

## M7: The stopgap leaves

**Goal.** erXos's kernel boots the slice and replaces the modified Fiasco.

**Demo.** The same boot image boots on erXos's kernel and runs the slice:
the system shell and the live machine, domains over connections and the
system domain's end as a reset, the command shell with its programs over
pipes, and files from EROFS and littlefs, with every test and benchmark
the slice ran on the stopgap.

**Exit criteria.** Every conformance, transcript and oracle difference
between the two kernels, the transcripts compared from erXos's banner on,
is a bug fixed, a documented improvement with a test, or a bug in the
stopgap recorded as such, K26's "at once" among the improvements; the
scheduler and messaging benchmarks meet or beat the stopgap's; quota
enforcement meets the draw-quantum accuracy of
[design-scheduler.md](design-scheduler.md#performance).

**Gate GK3.** Decides the replacement, from the conformance suite and the
slice's workloads: parity over the slice, which is all the stopgap
carries, as every stopgap's replacement needs. The fork leaves the tree
with its `TODO.md` item; the dependency table drops it.

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
devices; DMA confined behind the IOMMU.

**Demo.** A block transfer and a network ping run while the block driver
process and then the network driver process are killed; each supervisor
resets its device and restarts the driver; the shell never notices. The
inspector shows every driver as a process with its device's registers by
name.

**Scope.** The device service in full, with the system manifest's
placement of devices, its `/dev` tree and its boot-time refusal of a
manifest whose console differs from `/chosen/stdout-path`
([design-system.md](design-system.md#devices)); the device NIF in full:
the device NIF's address rule, under which an unconfined device's memory
is the system domain's for the boot and a confined device's is freed only
after the kernel unbinds it from the device's window,
resource binaries over pool buffers that return to the pool when
collected, transmit copies as per-byte C, interrupt acknowledgement, and
the build check that register accessors are referenced only from the
device NIF ([design-runtime.md](design-runtime.md#the-device-nif)); the
virtio console, block and network drivers in Erlang over virtio-pci,
written after sDDF's model of the driver-versus-policy split, with sDDF's
published throughput as the oracle and nothing imported, and M6's block
driver among them; the PCIe domain, `pcie@erxos`, whose enumerator, an
Erlang process, alone holds QEMU's PCIe configuration window and holds
nothing else, parses configuration space in Erlang with a fuzz target,
and programs MSIs and bus mastering at the device service's request, and
the devices domain, which holds the slow devices and no configuration
space ([design-system.md](design-system.md#drivers)); a driver for QEMU
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
about 5,000 lines of Erlang for three virtio drivers at a few hundred lines
each (sDDF's C drivers run 400 to 700 lines, and binary matching is no
longer), the PCIe enumerator with its fuzz target, the device service's
placement and `/dev`, the supervisors and the tests.

**Exit criteria.** Driver restarts under load lose no acknowledged data,
and a device reset after a driver's crash returns every posted buffer to
its pool; the drivers' descriptor parsers survive their fuzz budgets, a
hostile device model under QEMU writing malformed descriptors and
completions crashes at most the driver process and never the runtime; a
confined driver cannot DMA outside its window; a device given to a second
domain while the first holds it is refused; the PCIe enumerator's fuzz
target runs its budget clean; `/dev` reads every device's status, and
only the control facet's tree accepts `ctl` writes; the chokepoint check
over the register accessors passes with its seeded violation.

**Gate G9.** Measures, per device class, interrupt-to-handler latency
through the runtime's scheduler with `tools/erx bench irq`, the ring
throughput of each driver against sDDF's published figures for the same
device, `tools/erx bench blk` and the network driver's packet rate, and
the MSI path under HVF against wired interrupts. Decides completion
batching per device class, when virtio-pci replaces virtio-mmio, and, for
each device whose Erlang driver misses its timing or costs more than the
stated fraction of its throughput, a row in the driver table of
[design-system.md](design-system.md#the-driver-table) with its
measurement, which alone admits a native shim as a sub-space port;
without a row there is no exception.

## M10: Users without a container runtime

**Goal.** Principals with budgets, CPU shares and quotas; each user's
default domain.

**Demo.** Two users log in; each gets a domain; one exhausts its memory and
another its CPU share; only their own domains end or slow down.

**Scope.** The principal service, sessions, quotas and ceilings; principal
groups and budgets in the resource policy; facets for every service; the
console's login, which checks passphrases only from M11, when the vault
arrives, and the system-shell facet
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
console shows a login, and a session without the system-shell facet gets
no system shell; a host-link session holds exactly its configured facets;
an overlay survives its domain's restarts and the machine's reboots, and
is dropped when its release changes; each principal's hot store answers
only for its own blobs; the code service's decoder of overlays and stores
runs its fuzz budget clean.

## Track Q: The second tier

**Goal.** What programs that cannot be changed expect of a Unix, toward
what QNX offers: `fork`, the `exec` family, shared libraries, mappings of
files, pseudo-terminals with process groups and sessions, and the
console's terminal mode for full-screen programs
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
* pseudo-terminals with the line discipline as a pure state machine,
  process groups and sessions, `SIGWINCH`, and the console's terminal mode
  with its ECMA-48 parser and fuzz target
  ([design-live.md](design-live.md#terminal-mode));
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
mapping is gone; terminal
mode passes the allowlist and escapes every other sequence in the
terminal-mode corpus, and the console returns to its modes when the
program ends or leaves the foreground; the line discipline's exhaustive
model and the terminal-mode parser's fuzz target run clean.

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
([design-kernel.md](design-kernel.md#security)); credentials for
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
either fixed or recorded in `TODO.md` as accepted, with its reason.

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
sections of design.md. The network service gets its design document
before its code.

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
* **Networking.** The network service on lwIP, a NIF in the network
  domain's Erlang release, with a fuzz target for the packet path; the
  network driver an Erlang process of the same domain; the packet client
  and the Internet checksum among the per-byte primitives; TCP
  distribution to other machines, each exposed domain a distribution node
  of its own, whose node name is registered and resolved as the network
  service's design document defines ([design.md](design.md#networking));
  `crypto`, TLS and SSH on OpenSSL 3.5; and the **packet-path prototype**:
  Ethernet, IPv4, UDP and a TCP data path in Erlang over the packet client,
  enough for UDP echo and a TCP bulk transfer to a Linux peer, for gate GN.
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
a power cut after every write and every reset; on both boards, through the
board rig, a trial that panics, hangs, calls `halt/0`, loses power or
loses its system domain boots the committed slot next, and a damaged
boot-selection record is tried in place; a stopped watchdog pet on each
board resets it with a crash record, and the next boot's inspector shows
the record where the region survives; both boards boot with good entropy;
the packet path and the Internet checksum, the drivers' descriptor
parsers, the update manifest's decoder, the vault's purpose checks, its
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

**Gate GN.** Measures the packet-path prototype: UDP echo rate and
latency, and a TCP bulk transfer's throughput and CPU time, against a
Linux peer, on QEMU under HVF and natively on the Pi 4, each against lwIP
in the same network domain and, on the Pi 4, against Linux's stack on the
same board, with the host, accelerator, QEMU version, compiler and flags
recorded. The target is line rate at 1 Gb/s, 81,274 full-size frames a
second each way, 12.3 us a frame (computed from IEEE 802.3's framing).
It separately tests minimum-size frames (about 1.49 million frames/s at
1 Gb/s, 1e9 / (84 * 8), including preamble and inter-frame gap), invalid
packets, reassembly and connection floods, full duplex and overload recovery.
These are arithmetic offered-load targets, not measured throughput. Unowned
traffic has a finite per-interface CPU and memory budget before a client
can be identified; reserve control progress while dropping excess traffic.
Report p50, p99 and p99.9 and peer progress under load on matched setups.
Decides whether TCP's fast path in erXos's stack is Erlang or native code
([design.md](design.md#networking)).

## M13: erXos's F2FS

**Goal.** erXos's own read-write file system, F2FS implemented in Erlang
from its on-disk format, replacing littlefs at parity
([design-storage.md](design-storage.md#read-write-storage)).

**Demo.** An installation brings erXos's F2FS to the Pi 4; its files
survive power cuts and a later update's failed trial, and the Linux guest
mounts the same partition image.

**Scope.** The clean-room specification of the format, of the cleaner's
policies and of a read-only mount without recovery, as Linux's
`norecovery` mounts for a trial boot, written by one author from Linux's
documentation and sources who implements none of it, and the
implementation, in Erlang, from it alone; the feature bits it implements,
refusing the rest; the cleaner; the Linux oracle guest with `fsck.f2fs`;
the power-cut harness; the fuzz target; the installation that brings
erXos's F2FS, which creates the data partition and the vault's partition
afresh, with nothing littlefs wrote carried across, and the update
service's refusal of an update whose storage formats differ from the
running system's ([design-storage.md](design-storage.md#system-updates));
legal review of the clean room before a product ships it.

**Exit criteria.** Every image erXos's F2FS writes, and every state of the
power-cut harness, passes `fsck.f2fs` and mounts in the Linux guest at the
last completed checkpoint with every acknowledged `fsync`; a trial boot's
read-only mount without recovery writes nothing, so the partition after a
failed trial is byte for byte the partition before it, on erXos's F2FS
and on Linux's mounted with `norecovery`; the file-semantics corpus
agrees with littlefs and with Linux's F2FS, every difference a bug fixed,
a documented improvement with a test, or a bug in littlefs recorded as
such; and M11's closure holds over its work, as the ground rules require.

**Gate G13.** Measures erXos's F2FS against littlefs over the
file-semantics corpus and against Linux's F2FS in the oracle guest, the
power-cut harness's results, and throughput, commit latency and the
cleaner's overhead on QEMU and on the Pi 4's SD card. Decides the
replacement of littlefs.

## M14: erXos's network stack

**Goal.** erXos's own TCP/IP stack, written in Erlang, in the network
domain, replacing lwIP at parity ([design.md](design.md#networking)).

**Demo.** The TLS and SSH sessions of M12, and its distribution sessions,
run over erXos's stack on both boards, every
connection a process the inspector shows, and a network domain killed under
load comes back.

**Scope.** The network stack's design, in the network service's design
document, before its code; Ethernet, ARP and IPv6 neighbour discovery,
IPv4 and IPv6, ICMP, UDP and TCP in Erlang, grown from the packet-path
prototype, each connection a process; TCP's fast path in native code
behind the same process interface, only if gate GN decided so; the packet
decoders' fuzz targets, run on the host's stock OTP; the scripted packet
harness in the style of packetdrill, its scripts run against erXos's stack
and against Linux's in the oracle guest; the network test corpus run on
both stacks.

**Exit criteria.** Every difference between the two stacks over the
network test corpus is a bug fixed, a documented improvement with a test,
or a bug in lwIP recorded as such; every packet script passes against
erXos's stack as it does against Linux's, or its difference is
documented with a test; a network domain killed under load restarts
ending only its connections; and M11's closure holds over the stack, as
the ground rules require.

**Gate G14.** Measures throughput, latency and memory of both stacks on
QEMU and on both boards, and the corpus's differences. Decides the
replacement of lwIP.

## Decision gates

| Gate | Milestone | Measures or asks | Decides |
| --- | --- | --- | --- |
| G0 | M0 | the Fiasco set's licence scan and link closure; `lld` installed | what enters the tree, and the GPL-headed files the stopgap keeps |
| G1 | M1 | null call, IPC round trips through a gate, park and wake, deadline-to-resume latency, boot time to the root task, `tools/erx bench stop`, under HVF and TCG | timer slack, default time slice; whether the stopgap's tick accounting suffices until M7 |
| G2 | M2 | early E-S2 (kernel thread switch, IPC round trip through a gate, park and wake); E-S4 FIFO wake latency | whether the two-level model proceeds onto ERTS |
| GK1 | after M2 | the pilot's time and defect rate | the pace of the rest of track K and of the plan |
| G3 | M3 | W1 against stock OTP; footprint; boot time to the shell and to the first pet; E-S10 | default table sizes; the baseline; NIFs that move to dirty schedulers |
| G5 | M5 | E-D1 to E-D4 (`tools/erx bench xdomain-pingpong`, `xdomain-throughput`, `xdomain-stall`, `domain-lifecycle`); full E-S2; BeamAsm's speedup and footprint in an ordinary domain; translation time at a domain's start | `lane` and the manifest's `system_lane`, the producer's wait rule, encoding straight into the lane; the funnel's allowance per step; the manifest's `system_queue` and the death path's batching; the busy limit and the facets' limits; no kernel object per lightweight process; the ahead-of-time roster's triggers |
| GK2 | after M5 | the slice's interface complete, with its conformance suite and benchmark baselines in place | the start of erXos's kernel in full |
| GP | track P | a program's start (`tools/erx bench spawn`) against its budget and `posix_spawn` on Linux; the `make`-shaped workload and `tools/erx bench pipe`, hosted and under HVF | the channel's and data area's defaults; the handler's batching; one ring per write end; whether a program's start needs a cheaper path |
| G6 | M6 | the slice: an idle domain's memory by kind, a session's and a program's, the session services' floor and a facet's heap; E-D1 and E-D2; a program's start; isolation beside hostile domains; the EROFS reader's, littlefs's and the block driver's throughput and commit latency on QEMU (`tools/erx bench fs`, `blk`) | whether the slice meets the design's budgets before erXos's kernel takes it over; G5's lane defaults and the facets' limits confirmed or revised |
| GK3 | M7 | the conformance suite, the slice's transcript tests, the oracle and the benchmarks on both kernels | the replacement of the stopgap |
| G8 | M8 | E-S1 (the ladder C0 to C2), E-S3 to E-S9 | default cooperation features; time slice, grace and period; capacity rules; the shared services' sizing rule and whether a service needs a child group per client class |
| G9 | M9 | interrupt-to-handler latency per device class (`tools/erx bench irq`), ring throughput against sDDF's figures, `tools/erx bench blk`, the network driver's packet rate, MSIs under HVF | completion batching per device class; virtio-pci over virtio-mmio; each row of the driver table, which alone admits a native shim |
| GQ | track Q | `fork` of 10, 100 and 1,000 MiB against Linux in a guest; a dynamically linked program's start against a static one's; the fill and the write-back cost of the session's shared mappings, files of 64 KiB to 1 GiB, with `tools/erx bench mmap`, against descriptor reads and writes; on CPUs with hardware dirty-bit management, the fold of dirty bits into the object's stored marks at `munmap` and `exec` over large shared mappings, with `tools/erx bench mmap` | whether `fork` grows a copy-on-write path; whether the shared mappings' fill and write-back points meet the corpus |
| G12 | M12 | throughput and commit latency on the Pi 4's SD card, against G6's on QEMU; boot time to the shell and to the first pet on both boards; the trial path's timings; slot images' sizes | the default trial deadline; the watchdog's boot deadline per board; whether images need compression |
| GN | M12 | the packet-path prototype's UDP echo and TCP bulk transfer on QEMU under HVF and on the Pi 4, against lwIP, Linux's stack on the board and line rate | whether TCP's fast path in erXos's stack is Erlang or native code |
| G13 | M13 | erXos's F2FS against littlefs over the file-semantics corpus and against Linux's F2FS and `fsck.f2fs`; the power-cut harness; throughput, commit latency and the cleaner's overhead | the replacement of littlefs |
| G14 | M14 | both network stacks over the network test corpus; throughput, latency and memory on QEMU and both boards | the replacement of lwIP |

A numbered gate takes its milestone's number: M7's gate is GK3, and M4,
M10 and M11 have none. The research records are point-in-time reports and
use the gate names of the plan they were written against. The gates that
[research-baselines.md](research-baselines.md) names map here as follows:
its G2 to G1 (latency, measured there as interrupt latency and here as
deadline-to-resume latency), its G0 to M0 (repeating the ERTS
baselines with OTP 29.1.2), its G4 and G5 to G3 and G5 (the measurements
on erXos), and its G6 to G6 (the restricted decoder's cost under the
interpreter, within a frame's cost across a connection).

## Stopgaps

| Stopgap | Seam | Replaced at |
| --- | --- | --- |
| The modified Fiasco, with `bootstrap` and `sigma0` | the kernel interface: `abi/erx_abi.txt` and `liberx`'s backends | M7 |
| Accounting at Fiasco's 1 ms tick | the scheduler core | M7 |
| Virtio-mmio devices with ordinary interrupts and unconfined DMA, driven by the same Erlang drivers | DMA profiles; IRQ objects; the device NIF | M9 (virtio-pci with MSIs and the IOMMU), M11 (refused unless configured) |
| A host link holding every facet | session facet tables | M10, M11 |
| littlefs, the read-write file system of the data partition and the vault's partition, a sub-space port of their storage domains | `erx_fs`, the storage service's file interface, and the port's channel | M13, by erXos's F2FS, in Erlang, at G13, through an installation that creates both partitions afresh |
| Job control that stops only a job's Erlang commands, since the stopgap pauses no space | `erx_space_pause` and `erx_space_resume`, which fail with `ERX_ENOTSUP` on the stopgap | M7, by erXos's kernel's pauses |
| lwIP, the network stack, a NIF in the network domain | the network service's interface | M14, by erXos's network stack, in Erlang, at G14 |

The modified Fiasco carries only the part of the interface that the
slice uses. The stopgap's scope table in
[design-kernel.md](design-kernel.md#the-current-implementation-the-modified-fiasco)
lists, for each feature of the interface, whether the stopgap carries it
in full, carries it with a documented weaker guarantee, or leaves it to
erXos's kernel. A native driver shim admitted by a row of the driver
table ([design-system.md](design-system.md#the-driver-table)) is a stopgap
of the same kind as littlefs, a sub-space port behind the driver's
interface, and joins this table with its row.

## Critical path and parallel tracks

```text
                             +--> track S -+--> track P --> track Q (after M7)
                             |      ^      v<----+
M0 --> M1 --> M2 --> M3 --> M4 --> M5 --> M6 --> M7 --> M8 --> M10 --> M11 --> M12
 |             |      ^             |            ^ |            ^               |
 +--> track H -+------+             |            | +--> M9 -----+               +--> M13
               +--> GK1             +--> GK2 --> track K                        +--> M14
                   (pilot)
```

* The critical path runs through M0 to M5, then through track K from GK2
  to GK3, or through track S's programs, the first part of track P and
  M6, whichever takes longer, then through M7, M8, M10, M11 and M12. M9
  runs beside M8 once M7 is done, and M13 and M14 run side by side after
  M12.
* Track S starts with the shell after M4 and adds programs after M5;
  M6 needs them and the first part of track P, whose `erx_exec` runs
  executables from the EROFS images through `rx` grants, and needs the
  sub-space port that programs and littlefs share, so both run beside
  track K as part of the slice. The job control of programs follows M7,
  and track Q follows track P once M7 has brought erXos's kernel, whose
  copy-on-write children and copies of spaces the second tier rests on
  and the stopgap leaves out; neither is on the critical path.
* Track H starts with M0 and carries ERTS's port before the QEMU boot of
  M3; the pilot starts after M2; track K in full starts at GK2, once M5
  has completed the slice's interface, and ends at GK3, M7's gate.
* Host-buildable code (the C17 cores, the funnel and the lane reader, the
  domain library's plans, the device NIF's envelope, the pipe core,
  `erx_etf`) and its fuzz targets are written and tested on the host
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
   extractor with golden tests, the drift check, and the SVD file of QEMU
   `virt`'s console UART as the first input.
8. **Boot image.** `tools/erx pack` writing `ERXPACK`
   deterministically, with its `NOTICES` file, the C17 validator built for
   the host, and its fuzz target, landing together.
9. **Benchmark harness.** `tools/erx bench` recording every condition, and
   the host baselines with OTP 29.1.2.
10. **The fork boots erXos's image.** `bootstrap` running the C17 validator
    and the kernel starting `liberx`'s root-task entry as the root task
    from an `ERXPACK` image, under TCG and HVF, in a partial boot that
    prints a line and ends the machine.
11. **`liberx`'s first calls.** The generated calls with the `fiasco` and
    `hosted` backends for the debug log, and the chokepoint checks that
    confine kernel calls to `liberx` and Fiasco headers to its `fiasco`
    backend.
12. **The lane.** The lane's ring and reader page in the ABI file, the
    reader `erx_lane_take` with its chokepoint check, the exhaustive model
    of one lane and its fuzz target, built for the host, so the funnel and
    the pipe server build on a lane that is already proven.

## Beyond the plan

| Item | Why it waits | Decided |
| --- | --- | --- |
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
