# Working agreement

erXos is an Erlang-native, cross-platform operating system, targeting
AArch64 first. Its kernel
is a capability microkernel of its own, written in C on the design and know-how
of L4Re's Fiasco, with a process model built around lightweight runtime
processes; until it is written, a modified Fiasco stands in for it behind
the same kernel interface. The kernel allocates CPU time to native threads
and to runtime groups, and each runtime, ERTS first, schedules its own
lightweight processes within its grants. Every runtime runs in user mode,
including the one that runs the system services, which are mostly Erlang.
One process space, one message system and one view of identity,
supervision and inspection span them all.
[docs/design.md](docs/design.md) is the architecture and
[docs/plan.md](docs/plan.md) the staged roadmap.

## Principles

These shape every design and change; the rules below apply them.

1. **Erlang wherever practical.** Write as much of the system as is
   practical in Erlang, drivers included. Practical is the key word: do
   not complicate a design just to keep it in Erlang, and do not give up
   performance where it matters. Where Erlang does the job elegantly, use
   it, even if that means patching OTP.
2. **We own OTP.** Modify OTP freely when it makes the system simpler, more
   elegant or faster. Avoid gratuitous changes.
3. **Beauty and simplicity.** The system and its architecture must be
   simple and elegant. A small performance loss is acceptable when it buys
   a lot of simplicity.
4. **Declarative where it simplifies.** Describe the system declaratively
   wherever that is simpler: Datalog, awklog (`~/projects/awklog`), relic
   (`~/projects/relic`), Soufflé or another fitting language, never where
   it adds complexity. Extending the chosen language, or making a new one,
   is acceptable when that is what makes a description declarative and
   simple. Barrelfish's "Tackling OS Complexity with Declarative
   Techniques" and the BOOM project are the references
   ([research-os-ideas.md](docs/research-os-ideas.md)).
5. **UNIX look and feel.** To its users the system feels like UNIX, as QNX
   and Plan 9 do. A POSIX-like layer that runs FreeBSD programs, ported at
   the source level, is a goal, but not at the expense of the other
   principles; full POSIX compliance is not the bar. Programs brought in
   from elsewhere come from FreeBSD or are BSD-licensed where possible.
   Where UNIX systems differ and erXos must choose, it follows FreeBSD.

## Collaboration

* Ask, don't assume. If something is unclear, ask before writing a single line.
  Never make silent assumptions about intent, architecture, or requirements.
* Flag uncertainty explicitly. If you are not confident about an approach or
  technical detail, say so before proceeding. Confidence without certainty
  causes more damage than admitting a gap.
* Use plain language in explanations, progress updates and documentation.
  Name the concrete file, input, check or result. Say "build record" or
  "source record" rather than "provenance witness"; explain a technical
  term when it is necessary instead of stacking jargon.
* I'm always open to ideas on better ways to do things. Please don't hesitate
  to suggest a better way, or one that has long lasting impact over a tactical
  change.
* Security is paramount and on equal footing with correctness.
* **If you discover a bug, discrepancy, or something unexpected, fix it**
  whether or not it relates to the task at hand. Fix it if it is
  straightforward or required to make progress; otherwise document it in
  `TODO.md`.
* **Delegate with context, not checklists.** When handing work to an agent,
  give it the goal, the context and my constraints quoted verbatim; mark
  everything else as guidance and invite it to argue for a better approach.
  Never pass on a constraint I did not state as if I had.
* Read this file again after each context compaction.

## Delivery

* **A working system first.** The plan reaches a bootable, usable system as
  fast as possible by standing on third-party components (OTP, musl, a
  modified Fiasco, QEMU), then replaces or reshapes them one at a time where
  that pays. Do not build our own replacement for a stopgap before the
  system works unless the stopgap blocks progress.
* **Seams, not rewrites.** Every stopgap sits behind one of our own internal
  interfaces, so replacing it is a change behind that interface and nothing
  above it moves. The kernel interface, the boot image format, the host link
  protocol and the inspector schema are ours from day one; a stopgap never
  leaks its own data model or ABI to Erlang code or to users.
* **Development builds** run only trusted code until the security closure
  milestone of [docs/plan.md](docs/plan.md). Their boot banner says
  `development build: trusted code only`. Every other rule here applies to
  them as written. That milestone is reached on erXos's own kernel: the
  stopgap Fiasco is never hardened, though bugs found in it are fixed as
  anywhere else.
* **Two phases.** Phase 1 of [docs/plan.md](docs/plan.md) brings the
  system up on a near-stock Fiasco: `liberx`'s Fiasco backend implements
  the kernel interface over Fiasco's own calls in user mode, the system
  domain's `liberx` owns every kernel object and serves the other tasks,
  as L4Re's root task does, and nothing of erXos's kernel semantics is
  built into Fiasco. Phase 2 builds erXos's kernel with every guarantee.
  In Phase 1 the properties a kernel enforces are deferred as
  enforcement, not rewritten: isolation between domains, budgets as
  guarantees, stops and exit records, bounded kernel paths, the one
  route from user mode, no panic on a domain's input, and the kernel
  items of the "by construction" list in Design. The backend refuses a
  call it cannot implement over Fiasco with `ERX_ENOTSUP`, reports a
  value it cannot measure as unsupported or partial with its reporter
  named, and never rebuilds a kernel mechanism in user mode for a
  property that only erXos's kernel promises. Every rule below still
  binds the code written in Phase 1: `liberx`, the runtimes, the
  services, the drivers and the tools follow the untrusted-input,
  chokepoint, escaping, fuzz-target, generated-ABI and never-fabricate
  rules as written, and build against the target interfaces of the
  design documents, so that Phase 2 changes what is behind `liberx` and
  what the kernel enforces, not what services and runtimes call. Phase
  1's kernel carries no erXos C17 code, so the kernel stack proof and the
  kernel-side chokepoints have no site to check until erXos's kernel;
  their tools and tests stay.
* **A stopgap promises little.** Its design commits only to what the
  milestone using it needs and its tests check: no memory errors, no
  deadlock, and the results of the calls it offers, for trusted
  workloads. A call it does not offer fails with `ERX_ENOTSUP`, a value
  it cannot measure is reported as unsupported or partial with its
  reporter named, and no weakness of the stopgap is worked around unless
  the work is cheap or needed for its replacement anyway. Latency bounds,
  fairness, exact accounting and progress against hostile load belong to
  the component that replaces it; on the stopgap they are recorded as
  residuals, not engineered into inherited code. Its reviews check those
  commitments, not the target design's.
* **Nothing ships until I say so.** No one deploys erXos with stopgaps in
  production, so polishing a stopgap is throwaway work, even where untrusted
  input reaches it. What we need is to know where its gaps are: each is
  recorded accurately as a residual, and does not have to be fixed.
* **No backward compatibility in development.** Until a release promises
  compatibility, nothing erXos defines owes any to its own earlier forms.
  A change to a format, protocol, interface or stored state replaces the
  old form outright: no conversion, migration, compatibility shim or
  reader for old versions, and an installation re-creates what an earlier
  build wrote. Old state that no longer parses is refused with a
  diagnostic, never misread. Spend no design or implementation time on
  transitions. Behaving like stock OTP, musl and POSIX, as the tests
  require, is a different matter and stays a requirement.

## Dependencies

Third-party components are allowed when they pay for themselves.

* **Stopgaps.** To reach a working system, any third-party component may be
  used regardless of license or code quality. It stays until the roadmap
  replaces it. It is marked `stopgap` in the dependency table and has a
  `TODO.md` item to replace it. A stopgap under any license other than a
  permissive one (LGPL included) blocks any distribution outside the
  project, in source or binary form, until it is replaced. The one
  exception is the website's demo image, distributed with its source
  offered.
* **Design first, then fit what exists.** Assume every dependency can be
  modified. Arrive at the elegant, clear design first, unconstrained by what
  existing code does or assumes; only then work out how to reach it with as
  little modification of existing code as possible.
* **Code erXos modifies or ships enters the tree as erXos's code.** OTP
  29.1.2's source (ERTS and the applications erXos ships), musl, the Fiasco
  fork that serves as the stopgap kernel, littlefs, and toybox with `wak`
  live in the tree, keep their license notices and change by ordinary
  edits. Upstream is not tracked, so erXos owns their fixes, security fixes
  included. Each records its origin (repository, release or commit, and the
  SHA-256 of what was imported) in an `ORIGIN.md` beside it.
* **Forks as submodules.** A component erXos patches upstream-style may
  instead live as a git submodule of erXos's own fork (LVGL at
  `display/lvgl/lvgl`), pinned by its gitlink, with an `ORIGIN.md` beside
  it. Its patches are commits on the fork's `erxos` branch and follow the
  same ASCII and review rules as code in the tree.
* **Tools and test oracles stay out of the tree.** What only the build,
  the tests or development use unmodified (stock OTP as the oracle,
  libc-test, plan9port, Arm's machine-readable register data, the TLA+
  tools, the oracle guests) is fetched at a pinned version and verified
  against a pinned SHA-256. npm packages are verified against the integrity
  hashes of a checked-in pnpm lockfile and installed offline from the
  fetched store. Both are built out of tree.
* **Permanent dependencies.** Prefer mature, maintained components with a C
  or Erlang API and permissive licenses (ISC, BSD, MIT, Apache-2.0). A
  browser-side dependency of the web client may have a TypeScript API
  instead. A permanent copyleft dependency needs explicit agreement first.
* Record every dependency, with its purpose, license and status (`permanent`
  or `stopgap`), in the dependency table of [docs/design.md](docs/design.md).
* External tools are invoked as subprocesses, never linked: the compilers
  and linkers, QEMU, the stock host OTP build that bootstraps the cross
  build and serves as the behavioral oracle, `dtc`, and the LLVM binary
  tools.
* **New code is C17, Erlang and Ruby. No Rust, and no new C++.** The one
  exception is the stopgap Fiasco fork: kernel objects and scheduler hooks
  that integrate with its C++ may be C++, while the policy and pure state
  machines behind them are C17, ready to move into erXos's own kernel. The
  rest:
  * Assembly for the target architecture, only where C cannot express the
    operation: the boot entry, exception vectors, context switch, and
    sequences the architecture prescribes.
  * Ruby for host tooling: build orchestration, image packing, the QEMU
    harness, test runners (except the web client's own), generators,
    benchmarks, and the host console and upload client. Ruby never runs on
    the target.
  * TypeScript for the web client of [design-web.md](docs/design-web.md),
    because the browser runs only JavaScript. Its own tests and fuzz
    harness run under Node and Playwright. TypeScript never runs on the
    target or in host tooling.
  * `make`, minimal POSIX shell and linker scripts for build glue.
  * Inherited code keeps its languages and may be edited: OTP's BeamAsm JIT
    and asmjit (C++) with OTP's Perl generators and autoconf machinery, and
    the stopgap Fiasco (C++) with its Perl preprocessor and make system.
    Thin C shims onto inherited C++ are allowed. Inherited build machinery
    stays behind erXos's top-level build, so replacing it later is a change
    behind one seam.
  * Declarative languages for specifications, rules and checks where
    principle 4 makes them simpler than code: Datalog, awklog or relic,
    each once I have approved it.
  * Any other language needs a specific, stated reason, such as a category
    of language the tree does not have yet, and my approval before its
    first use. Never port working code or a working script to another
    language just to change its language.

Development tools are a separate question. If a build or development tool is
missing, install it via Homebrew (`/opt/homebrew`) or ask me to install it. Do not
work around a missing tool.

**Track every long-running command** (builds, QEMU runs, test suites,
benchmarks, external reviews), so nothing waits forever:

* Run it with standard input closed (`< /dev/null`) and its output in a log.
* Give it a hard deadline with GNU `timeout`, installed from Homebrew as
  `gtimeout`: `gtimeout -k 10 SECS cmd ...` sends SIGTERM at the deadline
  and SIGKILL ten seconds later. A wrapper that only arms `alarm` is no
  deadline: QEMU ignores SIGALRM.
* A QEMU guest is a long-running command. Run it with `-no-reboot`, serial
  output in a log and a deadline. Kill a hung guest; never wait on it.
* Check the log once, 30 to 60 seconds after starting, to confirm progress.
* Kill what you started as soon as it is no longer needed, and make sure no
  child process survives it.
* When reporting status, list every command still running, its age and its
  deadline.

**Keep shell commands simple**, so the permission hook can check them
instead of asking for confirmation. A command is one program with its
arguments, or a short pipeline of such commands. Loops, `case` statements,
nested command substitutions and `${var#pattern}` expansions go in a Ruby
script, written with the Write tool and run as `ruby SCRIPT ARGS`; scratch
scripts live in `~/erxos-scratch/tools/`.

## Design

* Code should be simple and clean, never over-complicate things.
* **Judge complexity by the model a maintainer must understand.** Compare
  the concepts, entities, independently varying states, ownership rules and
  coordination obligations a change introduces with those it removes across
  the whole system. Lines of code are a useful proxy for review effort, not
  an acceptance gate. A larger module is a win when it replaces scattered
  mechanisms with one clear owner and fewer rules for its callers. Moving
  the same obligations behind a new interface does not remove them. Follow
  the [architectural complexity guidance](docs/style.md#architectural-complexity).
* **Every serious subsystem gets a design first.** Write its design document
  and reference it from `docs/design.md` before implementation. The document
  explains the contract, invariants, authority and ownership, failure paths,
  interfaces and verification approach.
* **Use design subagents at the appropriate depth.** A Claude design
  subagent writes the design: Opus 5.5 at `high` reasoning effort for
  normal designs, at `xhigh` for complicated or critical ones, and at
  `max` for exceptionally complex ones. A Codex
  `gpt-6-astra` review at `xhigh` (at `max` for the most complex designs),
  in a read-only sandbox and with the
  security pass framed explicitly, then reviews the design, and its
  CRITICAL and HIGH findings are fixed before implementation starts. Give
  the design agent the goal, context and the user's constraints as
  required by the delegation rule above; invite it to challenge the
  approach. These are design-work settings; they do not change the
  separate code-review and external-review requirements.
* **Human readability is a requirement.** Follow the
  [readability standard](docs/style.md#readability-standard): another
  developer must understand purpose, data flow, invariants and failure paths
  without reconstructing the implementation or reading the conversation.
* **Functional core, effects at the edge.** Every decision that can be a
  pure function is one. Kernel and runtime code is a functional core (pure
  decisions, pure state machines that return the next action, and plans
  validated whole before anything is applied) around a thin layer of
  effects (page-table writes, scheduler effects, MMIO, message delivery).
  The core reads no hardware or global state, builds for the host and is
  tested there, exhaustively where it is a protocol state machine. Code in
  which the caller strings helpers together and must get their order right
  is the shape that keeps producing sequencing bugs; convert it. The
  [style guide](docs/style.md#functional-core) shows the patterns.
* **ERTS is a parts bin.** It is taken apart and recombined, or redone,
  wherever that makes the system simpler, faster or more elegant; what ERTS
  assumes today never constrains a design. The same holds for musl. The
  kernel reimplements Fiasco's proven design in C and keeps Fiasco's model
  wherever erXos needs nothing else; every departure, whether for erXos's
  needs or for an idea from research systems (SPIN, Singularity, Plan 9,
  Inferno, Genera), is recorded with its reason in the kernel's L4 lineage
  ledger. When a design keeps hitting issues, check how Fiasco, L4 and
  Zircon solved the problem before adding mechanism, and reverse a
  departure that has no recorded reason. CPU time has one authority, the
  kernel, and each runtime
  schedules its own lightweight processes within the kernel's grants.
* **System code is Erlang.** What erXos writes for the running system, the
  system services, the network stack and the file systems included, is
  Erlang unless that would cost too much performance; stopgaps may be
  native. Drivers are Erlang too: a driver is a supervised Erlang process
  over a thin device shim, and a native driver exists only as a measured
  row of the driver table. The kernel, `liberx`, the device shims and the
  per-byte primitives (checksums, hashes, compression, bulk copies) are C.
* If a design starts getting too complicated or convoluted, or accumulates a
  lot of edge cases, stop and re-evaluate the big picture. A pile of special
  cases is usually a symptom that the architecture is wrong. Step back and ask
  whether changing the architecture would make the edge cases disappear rather
  than handling them one by one. A simpler design that eliminates a class of
  problems beats a clever one that patches each instance.
* **Open-ended enumeration is the smell; "by construction" is the fix.** The
  warning is a correctness argument that depends on remembering every caller,
  execution path or exception that must participate in a protocol. Each new
  caller can invalidate that argument. An explicit enum or exhaustive switch
  over a closed set of states can instead make a design easier to understand;
  spelling out necessary cases is not itself a defect.
  * When review keeps finding missing participants or exceptions, stop adding
    entries. Ask what makes the enumeration
    necessary at all, and change that instead, so the property holds *by
    construction* rather than by exclusion:
    * make the illegal state unrepresentable;
    * make the invariant a derived fact nothing can destroy;
    * make the one funnel the only way to reach the operation.
  * Two questions get you there quickly: "what is this list protecting?" and
    "what would make the list empty?"
  * Prefer the answer that deletes mechanism over the one that adds it. A fix
    that is wider but shallower (many mechanical call-site edits, each failing
    loudly if wrong) beats one that is narrow but deep (a small clever
    interlock whose failures are schedule-dependent).
  * erXos's core works this way:
    * a stale capability never names a new object: every kernel call reaches
      objects through one lookup that checks generation, type and rights,
      and a capability slot retires before its generation wraps;
    * rights only shrink: duplicating or transferring a capability
      intersects its rights with a mask, and no call adds a right;
    * no capability is ever in flight: capabilities pass only at an IPC
      rendezvous, into slots the receiver reserved, so no queue holds one;
    * deleting an object invalidates every capability to it at once,
      because every use goes through the one lookup, and memory mapped
      from it faults from then on;
    * every kernel allocation is charged to a budget carved from its
      parent's, and an object dies with its budget: deleting a budget
      deletes everything charged to it at once, as EROS's space banks do,
      so what must outlive a party is charged to a budget that outlives
      it; a budget's guarantee is never taken by another budget; beyond
      its guarantee a budget spends only memory its ancestors have not
      promised to anyone, up to its cap; and a domain's budgets are
      walls, whose cap is fixed equal to their guarantee, so a domain is
      admitted or refused at its own budget alone and takes nothing from
      another's;
    * a mapping never allows more than the capability that made it: each
      mapping keeps a ceiling fixed from that capability's rights, and
      changing its protection moves only beneath the ceiling;
    * trimming never meets sharing: only private memory is ever freed by
      range, and private memory has no capability and each of its pages is
      mapped exactly once, so freeing a range never frees a page that
      another mapping still uses;
    * copy-on-write shares only immutable pages: a child's parent can never
      be written, and the child reserves every page it may copy when it is
      created;
    * a pid is a name, not an authority: a domain reaches a process of
      another domain only through an export that the owner's own runtime
      wrote, by handing out the pid, by a spawn, or explicitly, so knowing
      a pid grants nothing;
    * the system domain's atom table grows only within bounds its own
      policy sets: no frame to its processes creates an atom, and the
      only atoms it makes from a request are node names, within the
      requesting principal's quota;
    * no mapping is ever writable and executable at once, and the kernel
      writes no machine code: JIT compilers run only in user-mode runtimes;
    * the right to make code follows from the image: only images their
      image manifest marks for JIT get spaces that allow JIT objects, and
      the system domain's image is not one, so the trusted base makes no
      code;
    * no file grant carries write and execute together, so a program never
      runs what it could rewrite;
    * a path never reaches a server the domain does not hold: a domain's
      namespace is a private table from paths to grants, and each file
      server roots a grant at its subtree;
    * end of stream follows from who holds a pipe's ends: the session
      alone installs every end into its programs and records each holder;
    * a space never outlives its parent: every space names its parent at
      creation and stops when it stops, so no program outlives the domain
      that started it, no sub-space outlives its creator, and nothing is
      orphaned;
    * no process acts on a message from another domain that its protocol's
      owner did not admit: every such message arrives as
      `{erx_origin, D, Msg}`, with no flag and no exception, and only each
      protocol's owner takes the envelope off its own shapes, never `sys`;
    * the kernel, `liberx` and its backends, the runtimes and Erlang agree
      on the ABI because all of them are generated from `abi/erx_abi.txt`.

    Keep new mechanisms in that spirit.

## Code

* Follow the [style guide](docs/style.md). It covers C, assembly, Erlang and
  Ruby layout, naming, `_t` typedefs, comments, the BSD memory primitives,
  and the rules for kernel and freestanding code.
* **The stopgap Fiasco keeps its own style.** Its inherited C++ is exempt
  from the kernel-construction rules below: the stack proof,
  `musttail`-only recursion, the chokepoint checks and generated register
  access. Those rules bind erXos's own kernel and the C17 code erXos adds
  to the fork.
* Watch the argument order of `bcopy(src, dst, n)`, the opposite of `memcpy`.
  Flag it in code review.
* **Trust placement.** Only the kernel runs in kernel mode: erXos's own C
  microkernel, or until it is written, the modified Fiasco that stands in
  for it. Every runtime runs in user mode, including the system domain's
  ERTS, which runs the trusted Erlang system services. Mechanism
  that every domain's isolation depends on lives in the kernel. The
  system domain is the root task: a C17 domain library in `liberx` builds
  and ends domains, Erlang policy in the system domain decides who gets
  what, and a fault of the system domain resets the machine. A domain's
  memory, threads and CPU grant depend on nothing outside itself except
  the kernel; which processes may message it depends on the kernel and on
  its own runtime's funnel and export table, and on nothing else. A
  device belongs to the domain its capabilities are installed in, by
  configuration, which is one system manifest whose security properties
  a build check proves; the PCIe enumerator, Erlang in the PCIe domain,
  which holds nothing else, alone reaches configuration space; the kernel
  touches none.
  Code of unknown provenance runs only in an address space of its own, a
  domain or a sub-space that a domain created, holding only the capabilities
  it was handed.
* **The ABI and the hardware each have one source.** Kernel calls, rights,
  status codes, limits and every fixed binary layout, in-memory device
  structures included, are defined in `abi/erx_abi.txt`, with each
  architecture's call registers and hardware layouts in `abi/arch/<arch>.txt`.
  Memory-mapped device registers are defined in CMSIS-SVD files and each
  architecture's system registers in one checked-in specification. Ruby
  generators produce every header, accessor and table from these sources
  during the build. Never edit a generated file, hand-pack register bits or
  copy a constant by hand.
* **Untrusted input.** Everything a domain hands the kernel (registers,
  addresses, lengths, capabilities), every message from another domain,
  everything a device writes to shared memory, every byte from the host
  link, every network packet and filesystem image, and every code artifact
  a user supplies is untrusted, wherever it arrives.
  * Bounds-check every parse, and use checked arithmetic on every size,
    offset and count read from input.
  * The kernel never loads or stores through an address a domain
    supplies: every kernel call argument is a register, a field of the
    calling thread's UTCB, or a memory object, offset and length that the
    kernel reaches through its own mapping, so a domain cannot change a
    value between its check and its use. Kernel
    memory that user mode can write (UTCBs, vCPU state areas, shared areas)
    it reads only through accessors that load each field once per decision.
  * Never let input-controlled depth drive unbounded recursion. Kernel C
    code recurses only through calls marked `musttail`, which compile to
    jumps or fail to build.
  * Fail with a diagnostic, never with a crash. Nothing a domain or a device
    does can panic the kernel: a malformed request fails with an error, and
    a fault ends only the faulting domain. The one exception, a device error
    the hardware reports too late to attribute, is a security residual in
    `TODO.md`.
  * Every kernel allocation is charged to a budget. A service admits a
    domain's requests only through that domain's facet and lane, on the
    service's own grant, so what one domain can make another spend is
    bounded and declared.
* **Text from untrusted sources** (domains, devices, the network, uploaded
  artifacts) reaches a sink that shows text (the kernel log, a console
  line, the host terminal, a window or widget, and the browser) only
  through that sink's one escaping function. Raw control characters on a
  terminal are an attack (ANSI and OSC escape injection) on the operator's
  host, so the escaping covers C0 and C1 controls, bidirectional overrides,
  invisible format characters and invalid UTF-8. Text attributed to a source
  (log records, names, inspector output, what the host tool prints from a
  guest) escapes tab and newline too. A program's own output is not such
  text: as on UNIX and QNX, `write` and stdio deliver its bytes unchanged to
  a tty, which does only `termios`-style processing.
* **Generated files are not checked in.** The build generates them into the
  build tree from their checked-in inputs (the ABI files, the hardware
  specifications, the generators themselves), so the inputs are the only
  copy. Commit the input and the generator, never the output.
* **Generated code is code too.** Generated C, Erlang and headers must be
  readable, ASCII-only and free of undefined behavior, and are produced by a
  Ruby generator checked into the tree.
* **Chokepoints are build checks.** Every rule of the form "only X may do
  Y" is enforced by a check that fails the build on a new site, and every
  check has a test proving it catches a violation. For example: only a
  console line's own sink (the UART driver's, a terminal window's
  emulator) writes bytes to that line; only listed functions execute system-register
  instructions or inline assembly; kernel allocation goes only through the
  budget-charging funnel; the kernel executes no FP or SIMD instruction;
  data holds no code pointer outside an allowlist; only `erx_cap_slot_clear`
  clears a capability slot; `liberx`'s entry macro opens every exported
  function of its program layer, which never calls musl's `malloc` or
  stdio; only `erx_elf_plan` reads executable headers, only `erx_image_plan`
  reads image-manifest segments, only `erx_exec`
  copies code into a program, and only `liberx`'s loader maps code; only
  the funnel reads a lane's ring; only the device shim touches a device's
  registers; only the block driver's one write path issues writes. The
  design documents keep the full list.
* **Kernel stacks are proven.** Every build computes the kernel's
  worst-case stack depth from each entry point (boot, secondary boot,
  synchronous exception, interrupt) from per-function stack sizes and the
  call graph. A frame over the cap, an indirect call without its listed
  targets, or a cycle through a call not marked `musttail` fails the build.
  Kernel stacks have guard pages.
* **Subprocesses** in host tooling are started with an argument vector, never
  through a shell.
* **No implicit network access.** Third-party sources are fetched only by an
  explicit fetch step against pinned URLs and hashes; builds and tests then
  run offline. A guest gets a network device only when a test asks for one.
* **Third-party sources and images are untrusted data.** They are verified
  against their pinned hashes before use and unpacked in their own
  directories under the build tree. Do not run their scripts or makefiles
  outside the documented build steps without review. Fixtures in the
  repository must be legally redistributable.
* **Portability.** Apple Silicon macOS is the primary host, then Linux
  (AArch64, x86-64). erXos is cross-platform: AArch64 is the first
  architecture, QEMU `virt` the first target, and the Raspberry Pi 4 and
  then the Raspberry Pi 5 follow; other
  architectures and platforms are ports, not redesigns. Keep
  architecture- and board-specific code behind the architecture and
  platform layers so ports stay mechanical. Generic designs, interfaces and
  names are architecture-neutral: they say kernel mode and user mode. An
  architecture's own terms appear only in its layer and its design
  documents, which `make check-arch-terms` enforces.
* **No temporal or campaign-specific marks.** Do not leave them in code,
  comments, doc strings, design docs or user-facing docs: no "now fixed",
  "previously broken", "as of <date>", "Wave 3", "Addressing BUG-12", "(fixed
  in commit abc123)". Code and docs describe the current state of the system.
  The why-and-when belongs in commit messages, which are read in temporal
  context.
* **erXos-authored source files and generated output are ASCII-only.** This
  covers `.c`, `.h`, `.S`, `.erl`, `.hrl`, `.rb`, `.ts`, `.tsx`, linker scripts, build files
  and shell scripts; `make check` fails on any byte > 0x7f in erXos-authored
  code or generated output. Imported upstream text keeps its original
  copyright names, notices and comments; erXos-authored additions are ASCII.
  Markdown prose is exempt.

## Ruby style: functional, idiomatic, elegant

Use the installed Ruby; no specific version is required. Ruby is host
tooling only: write code that reads like the
problem, not like Java or a shell script. The language rules above still
apply; this section grants no additional language exceptions. Follow
[the Ruby style guide](docs/style.md#ruby) as well as these principles.

**Prefer:**

* Immutable values: `Data.define` where available, frozen `Struct` instances,
  `# frozen_string_literal: true`, and frozen constants and configuration.
* Pure functions and pipelines: `Enumerable`, `Enumerator::Lazy`, and,
  where available, `then`, `filter_map`, `each_with_object`, `sum`, `tally`,
  `group_by` and `zip`.
  Prefer these to index loops. Keep process execution, filesystem changes
  and other effects at the edge, around a pure decision core.
* Small objects with one job. Use `call`-style callables for steps when
  composition makes the flow clearer:
  `steps.reduce(input) { |value, step| step.call(value) }`.
* Keyword arguments for interfaces with more than two parameters, and for
  flags. No positional boolean flags.
* Pattern matching (`case ... in`) where the installed Ruby supports it
  for shape-dependent logic, including deconstructing structured responses.
* Explicit domain errors under `Erx::Error`. Raise a typed error on failure;
  do not return `nil` to mean failure. Use `nil` only for an absent value,
  and distinguish lookup names such as `find_entry` from `fetch_entry`,
  which must return an entry or raise.
* Endless methods for clear one-liners where supported. Keep normal bodies when
  control flow, cleanup or explanation needs more space.
* Private implementation methods and the smallest public surface.

**Avoid:**

* Mutating arguments or shared state; use `!` methods only on values the
  operation just created and owns. Local mutation is appropriate for
  building a result or implementing an effect, with ownership explicit.
* `unless ... else`, nested ternaries, `and`/`or` as control flow, and
  untyped catch-all rescues. Translate expected boundary failures into a
  typed error; propagate errors that cannot be handled. Cleanup must
  preserve the original exception.
* Monkey-patching core classes and third-party gems. Use wrapper objects
  or narrowly scoped refinements.
* Service classes that are bags of static methods. Group stateless
  functions in a module; use objects when they own state or resources.

For example, selection should express the predicate directly:

```ruby
PackLimits = Struct.new(:max_file_bytes, :max_entries, keyword_init: true)
DEFAULT_PACK_LIMITS = PackLimits.new(max_file_bytes: 1_048_576,
                                    max_entries: 65_536).freeze

def oversized_entries(entries, limits:)
  entries.select { |entry| entry.byte_size > limits.max_file_bytes }
end
```

**Metaprogramming where it earns its keep.** Use it to remove repetition
that mirrors data, never for cleverness. Suitable uses include generating
accessors or validators from validated declarations, small DSLs for
declarative registries and checks, and `Module#prepend` for cross-cutting
instrumentation such as timing and run records. Keep the ABI and hardware
sources and their generated-file checks as defined above; load-time
metaprogramming does not replace readable checked-in generated outputs.

Generated methods must satisfy `respond_to?` and appear in `methods`.
Public APIs do not use `method_missing`. Never use `eval` with string
interpolation. Every metaprogrammed surface has a comment explaining what
it generates and a test exercising a generated member. If plain code is
within about 20 percent of the length, write plain code.

## Tests and sanitizers

* Write the tests that would catch a real break in what you build: its
  behaviour and its main failure paths. Do not write tests of the test
  tooling or exhaustive matrices, except for a protocol state machine,
  which is tested exhaustively.
* **Seeded faults prove a check catches what it guards.** Where a design
  names a seeded fault, or a property test, fuzz target or build check
  guards something subtle, plant the fault (a removed bound, an off-by-one
  comparison, a dropped key) and confirm the check fails on it. Keep the
  seeds few and aimed at the failure the check exists for.
* **Two tiers of gates. Iteration speed comes first.**
  * **Landing gate**, for every commit and batch: `make check`, and the
    QEMU suites the change touches.
  * **Milestone gate**, before a milestone is declared reached or a large
    branch merges, and in the background on a spare host:
    `check-oracle`, `check-asan`, `check-ubsan`, `check-tsan`, the
    `check-fuzz` budgets, `check-reproducible`, `check-cbmc`,
    `check-tla`, `check-litmus` and the full QEMU suite.
  * A milestone-gate failure is fixed forward with a regression test. It
    holds nothing that already landed unless it also breaks the landing
    gate.
* When fixing a non-trivial bug, write a regression test FIRST.
  * It must exercise the broken path, and you must confirm it actually fails
    against the unfixed tree. Only then apply the fix and re-run the test to
    confirm it now passes.
  * A fix without a failing-then-passing test is not a fix. It is a guess that
    happens to compile.
  * Trivial typo and one-line obvious-correct fixes are exempt. Anything
    involving boot, exceptions, page tables, physical memory, the scheduler,
    the kernel entry and the UTCB accessors, capabilities, IPC, the C
    library seam under ERTS, cross-domain messaging, term decoding, device
    drivers, image packing, memory ownership, or a multi-step code path is
    not trivial.
* **Agreement with ground truth is the correctness criterion.** Behavior that
  disagrees with an independent oracle is a bug until it is explained and
  pinned by a test. The supporting rules:
  * **erXos's Erlang behaves like stock OTP.** OTP 29.1.2's own test suites
    run on erXos and on stock OTP 29.1.2 on the development host, and their
    results are compared; every difference is a bug in erXos, a documented
    difference with a test, or an upstream bug recorded as such.
  * **erXos's C library is checked against musl's own tests**: `libc-test`
    runs against erXos's musl in a test domain; every failure is a bug,
    a documented difference with a test, or an upstream bug recorded as
    such.
  * **The funnel is checked differentially** against `binary_to_term/1`:
    every payload it accepts decodes to the same term.
  * **Architectural behavior follows the Arm Architecture Reference Manual**
    and the QEMU `virt` documentation. QEMU's suites run under HVF; TCG
    runs only the deterministic-mode transcript and a boot smoke test, and
    Linux hosts are not tested until the plan reaches them. A failure seen
    under one accelerator only is still a bug until explained.
  * **Replacing a stopgap is gated on parity.** The replacement is run
    differentially against the stopgap over the test corpus; every
    difference is a bug in the replacement, a documented improvement with a
    test, or a bug in the stopgap recorded as such.
  * **Never fabricate.** The inspector and every report show unknown,
    partial, unsupported and timed-out results as such, and each status has
    a test.
  * **Determinism.** The same inputs produce byte-identical boot images
    (`make check-reproducible`, at the milestone gate), and a boot in deterministic mode
    (`erx.det=1`, single-threaded TCG with instruction counting) produces a
    byte-identical transcript.
* **Every parser of untrusted input has a fuzz target, landing with the
  parser**: the device tree, the boot image, image manifests and boot
  information, the system manifest's reader, system-call argument
  decoding, `prim_file` path resolution and namespace paths, the 9P2000.L
  codec, the program startup message and protocol, executable headers (`erx_elf_plan`), log records, the funnel,
  cross-domain frames and their reassembly, the host link deframer, device
  ring processing, PCIe configuration snapshots, `/proc` names, the command
  shell's parser and `grep`'s pattern translator, each line escaper, the
  partition table, EROFS, F2FS, littlefs and FAT images, update manifests,
  the boot-selection record, the harness's slot parser, the pipe ring and
  record checks, the pipe reader page, the pipe protocol frames, the
  line discipline's input and `termios` checks, the tty's messages between
  domains, the per-byte primitives, the host tool's decoder, the draw
  protocol decoder and its C twin, the image `Y` decoder, the `wctl`
  grammar, the terminal emulator's control sequences and OSC 8 links, the
  widget tree validator and every `ui.txt` reader, the input event
  validator, virtio-gpu responses and virtio-input events, the touch,
  keypad and encoder parsers, the web protocol codecs (Erlang and
  TypeScript), the host tool's HTTP and WebSocket reader, and the HTTP and
  WebSocket parsing of the web front end's server (cowboy, cowlib, ranch)
  as the front end uses it. Fuzz targets build the same sources for the host;
  `make check-fuzz` runs each for its configured budget, at the milestone
  gate.
* **`make check-oracle`** runs OTP's suites on erXos and on stock OTP
  29.1.2 on the development host and compares them case by case, and runs
  musl's `libc-test` in a test domain. It runs at the milestone gate,
  and on demand before landing a change to ERTS or musl risky enough to
  want it.
* **Latency is UX.** Changes to the boot path, kernel entry, scheduler, IPC,
  domain creation or cross-domain messaging come with before/after numbers
  from `tools/erx bench <name>`. Any performance number written into docs
  states host,
  accelerator (TCG, HVF or native), QEMU version, compiler, flags, workload
  and baseline. TCG numbers are never compared with HVF or native numbers.
* **Suspected costs go on the watch list.** When a design, review or
  change leaves a cost unmeasured that could matter (a slow path, a
  portable fallback, a contended lock, a copy), add it to
  [docs/todo-performance.md](docs/todo-performance.md) with the
  measurement that settles it, and remove the item once a recorded
  number does.
* **Host builds of kernel and library code.** Code that does not touch
  hardware (allocators, capability tables, scheduling policy, validators,
  the C library seam) also builds for the host, so its unit tests, fuzz
  targets and sanitizers run there.
* **Hosted mode** runs a runtime and its system services as a macOS process
  on a hosted implementation of the kernel interface, under the sanitizers
  and `lldb`, for fast iteration. The QEMU suites remain authoritative.
* **`make check-asan`** rebuilds the host test builds with AddressSanitizer
  and runs them with strict `ASAN_OPTIONS`.
  * Leaks, use-after-return and init order fail the run. (LeakSanitizer
    is not available on macOS; leaks are caught on Linux.)
  * Allocations may return NULL, so failure handling is exercised.
  * Treat any ASan report as a HIGH finding and fix the root cause. A report
    inside a stopgap is recorded in `TODO.md` and, if reachable from a
    malformed input, added to the test corpus.
  * It runs at the milestone gate. Run it before landing a change to an
    allocator or to a C parser of untrusted input.
* **`make check-ubsan`** runs the host test builds under
  UndefinedBehaviorSanitizer and boots a kernel built with UBSan in trap
  mode through the QEMU suite. It runs at the milestone gate, and on
  demand when a change to bit-level or offset arithmetic wants it before
  landing.
* **`make check-tsan`** runs the host concurrency tests under
  ThreadSanitizer. It runs at the milestone gate, and on demand when a
  change to locks, atomics or state shared between CPUs wants it before
  landing.
* **`make check-lsan`** (standalone LeakSanitizer) and **`make check-msan`**
  (MemorySanitizer) run on Linux where available, and are no-ops elsewhere.

## Committing

* Each solid progress should be committed in the git repository.
* Before committing code, test that what you produced is high quality and that
  it works:
  - Launch a code-review subagent **FIRST**, before running tests. Ask it to
    enumerate bugs, design issues, AND security / information-leak concerns.
    Frame the security pass explicitly in the prompt; don't assume the agent
    will check on its own.
  - Ask the reviewer to apply the style guide's
    [readability review](docs/style.md#readability-review). Require specific
    functions or passages as evidence. Formatting,
    comment count, and passing tests are insufficient. Address readability
    findings before committing. For an architectural change, require a
    before/after comparison of the concepts and maintenance obligations added
    and removed across the system; a line-count delta alone does not establish
    simplification.
  - Address every CRITICAL and HIGH finding before committing. Note MEDIUM
    findings in `TODO.md` or the commit message if not fixed.
* **External review.** Designs and complex code changes also get an external
  review once the internal reviews pass:
  - A design's external review is the `gpt-6-astra` review of the design
    subagent rule above. A code change's external review runs with the Codex
    CLI, model `gpt-6.1-sol` at xhigh reasoning effort (high when the code
    is not especially complex), in a read-only sandbox:
    `codex exec -m gpt-6.1-sol -c model_reasoning_effort='"xhigh"' -s read-only -C <tree> "<prompt>" < /dev/null > review.log 2>&1`.
    Frame the security pass explicitly, as for internal reviews.
  - Close its standard input: without `< /dev/null`, `codex exec` in the
    background waits on stdin forever and prints nothing more. `-o FILE`
    cannot write under `-s read-only`, so take the review from the log: it
    is the last `codex` block before the `tokens used` line. Track the run
    like any long-running command; a review of the full design takes about
    15 minutes.
  - Run it once per milestone, after every internal CRITICAL and HIGH finding
    is fixed. A milestone is a design ready for implementation or a large
    branch ready to merge. Batch related changes into one pass. Do not run it
    per review round or for small or doc-only changes; it is slow.
  - Its findings follow the same rules as internal findings.

## Documents

* **Document roles.**
  * [docs/design.md](docs/design.md) is the architecture.
  * [docs/plan.md](docs/plan.md) is the staged roadmap, with exit criteria and
    decision gates.
  * [docs/style.md](docs/style.md) is the code style guide.
  * [TODO.md](TODO.md) is the index of open work outside the roadmap.
  * Research records (`docs/research-*.md`, measurement and conformance
    reports) are point-in-time reports.
* **For every major feature, write `docs/design-<feature>.md` first** and
  reference it from `docs/design.md` before implementation.
* **Design docs describe the target design, in the present tense.**
  * Edit them when the design changes, not to record what shipped, what was
    deferred, or which parts are not built yet. That belongs in `TODO.md`, and
    scheduling belongs in `docs/plan.md`.
  * A design doc is never trimmed to match a partial implementation. A
    stopgap is described as the current implementation behind an interface
    the design owns, not as the design.
* **Research records are point-in-time reports.** They state the date, host,
  tool versions and sources they were checked against. Update a number by
  re-measuring or re-checking it, never by editing it in place.
* **Where decisions live.** A decision that constrains more than one subsystem
  is recorded, with its rationale, in `docs/design.md`. Any other decision
  lives in the design doc it shapes. When a decision changes, edit it in place;
  git holds the history.
* **`TODO.md` structure.** It is split into categories: major initiatives,
  stopgap replacements, bugs by subsystem, security residuals, planned
  features.
  * Each item has a `[Severity]` tag (Critical / High / Medium / Low) and a
    component pointer.
  * Small items live inline as one- to few-line bullets.
  * Larger initiatives fan out to category docs in `docs/todo-*.md` and are
    referenced from `TODO.md` by a one-paragraph summary. Each category doc
    follows the same rule recursively: small items inline, anything beyond
    about a page splits into its own file linked from the category doc.
  * When an item is closed, delete it. Git history is the record of completed
    work.
* **`TODO.md` holds only work worth doing.** Do not add an item for something
  not worth fixing, or for behaviour a design doc already states as a contract
  or limitation. A limitation users should know about belongs in the
  user-facing docs, not in `TODO.md`.
