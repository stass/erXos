# erXos plan

The staged roadmap from an empty tree to protected Erlang domains, users
and a release build on QEMU `virt`, and then to storage, networking and
the first boards. Each milestone ends in a demonstration that a QEMU
transcript test, or on a board the hand test of 1b-I, reproduces, and has
exit criteria that tests check. Where the design rests on a number nobody
has measured, or on a choice not yet made, a decision gate
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
  offer refuses, a value it cannot measure reports unsupported, and a
  Fiasco bug found on the way is fixed, in the fork or in the backend,
  unless its fix would rebuild erXos's kernel design inside Fiasco.
  Phase 1b carries
  the user-facing system further on Fiasco, behind the same
  interface, with every guarantee still deferred: domains and their
  connections, programs and pipes, the POSIX-lite first part, the
  browser and the desktop, drivers in their domains, storage and
  networking on QEMU, and the Raspberry Pi 4. Each guarantee a Phase 1b item defers is a row of
  one list, [Downsides against erXos's kernel](design-fiasco.md#downsides-against-erxoss-kernel),
  naming the milestone that closes it, and `TODO.md`'s security residuals
  point to that list rather than copy it. 0.1, the first public preview, is published: a
  development build of part of that system, on the Raspberry Pi
  4 and QEMU `virt`. 0.2, erXos's first full release,
  ships on Fiasco with every user feature: the backend uses Fiasco's own
  capabilities, factories, interrupts and DMA spaces, the release
  reaches a security closure in its Fiasco form, and what Fiasco lacks
  against erXos's kernel is a published list of downsides, not rebuilt
  in user mode ([design-fiasco.md](design-fiasco.md)). After 0.2,
  track F improves Fiasco to a stated point, each stage closing or
  narrowing rows of that list in ways that fit Fiasco's own approach,
  and gate GF then decides whether erXos builds its own kernel
  ([Track F](#track-f-fiasco-improved-to-the-decision)). If it does,
  Phase 2 builds erXos's kernel with every guarantee, boots the same
  boot image, and replaces Fiasco at parity over 0.2's system, and the
  rows track F leaves close on erXos's kernel alone; if it does not,
  they stay published downsides.
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
* **The oracle runs on a schedule.** OTP's `emulator`, `kernel`,
  `stdlib` and `compiler` suites run on erXos, in the system domain until
  1b-A brings domains and in a test domain from then on, and are compared
  case by case with stock OTP 29.1.2 in the host's isolated Linux oracle
  ([design.md](design.md#testing-and-the-oracle)). A fast subset runs with
  `make check` on every change; the full suites at every major change (to
  the kernel or Fiasco, the scheduler, memory, the funnel and the
  connections' carrier, the adapter, the loader, or the build of OTP or
  musl) and at each milestone's exit. `make check-oracle` also runs musl's
  `libc-test`, and from M13 erXos's F2FS's deep runs against Linux's
  ([design-f2fs.md](design-f2fs.md#where-each-test-runs)). A case that cannot run yet is never a pass: the run shows it as
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
* **Stopgaps and Fiasco sit behind seams and leave on parity.** Neither leaks
  its formats. [Stopgaps and Fiasco](#stopgaps-and-fiasco) names the milestone that replaces each;
  a third-party stopgap also has its `TODO.md` item, while a stopgap
  mechanism of erXos's own is tracked here alone. The replacement runs
  differentially against Fiasco over the test corpus, which for the
  kernel is Phase 1 and 1b's system's; every difference is a bug in the
  replacement, a
  documented improvement with a test, or a bug in Fiasco recorded as
  such.
* **Checks before the code they police.** The generators and the
  generated-tree tests, the stack proof and each chokepoint check land before or with the first
  code they constrain; every parser of untrusted input lands with its fuzz
  target.
* **Development builds run only trusted code** until the security
  closure, 0.2's on Fiasco and M11's on erXos's kernel, and say so in the
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
shell of track S, brings the system up on Fiasco. Phase 1b
carries the user-facing system further on Fiasco, in ten items
named 1b-A to 1b-J: M5's domains (1b-A), the programs of track S (1b-B),
track D's browser, window stack and QEMU kiosk (1b-C), track P's first part (1b-D),
M9's drivers in their domains (1b-E), track D's desktop and Plan 9's
programs (1b-F),
networking on QEMU (1b-G), M13 on QEMU (1b-H), the Raspberry Pi 4
(1b-I) and the Raspberry Pi 5 (1b-J), each with the backend
rows it needs and its guarantees deferred; track A comes with them: its
first part, the start table, for track D's window stack, its second,
apps packaged outside the tree and added to an image, for track D's
kiosk, and its third, installing packages at run time.
0.1, the preview, erXos's first public preview, is published: a
development build of part of that system on the Raspberry Pi 4 and QEMU
`virt`, with the kiosk, SSH to `rc` and Doom in its images
([0.1](#01-the-preview)).
0.2, the first full release and the target the work is ordered towards,
ships that system on Fiasco with every user
feature, the backend on Fiasco's own mechanisms and the security
closure in its Fiasco form, and what Fiasco lacks against erXos's
kernel published as downsides ([design-fiasco.md](design-fiasco.md)).
Beyond Phase 1b and track A, 0.2
takes M9's devices, the rest of track P, M10, M12, track D's parts 5
and 9 and M11's closure, each in its Fiasco form, ahead of erXos's
kernel; track Q follows 0.2 ([0.2](#02-the-first-release-on-fiasco)).
Track F follows 0.2: it improves Fiasco, Fiasco's scheduler stages
among its stages, up to the point where gate GF decides whether erXos
builds its own kernel
([Track F](#track-f-fiasco-improved-to-the-decision)).
Phase 2, track K, M7, M2, the
kernel parts of M5 and M9, the rest of track P, M8, M10, track Q, M11,
M12 with its boards and track D's last parts, builds erXos's kernel,
switches to it at parity over 0.2's system, and adds
everything that needs a guarantee Fiasco lacks on it alone; it is the
plan if gate GF chooses erXos's kernel. Track K's
pilot, the host-built C17 cores, starts before Phase 1 is complete and
continues whatever GF decides, since Fiasco links its cores; its kernel
in full waits for GF. Milestone
numbers are names; the table's order is the order.

| Milestone | Demo | New code (estimate) | Needs | Gate |
| --- | --- | --- | --- | --- |
| **Phase 1** | | | | |
| M0 The tree, the toolchain and the oracle | focused stock OTP 29.1.2 cases verify the offline Linux test runner; native Mac OTP supplies bootstrap tools; the frozen Fiasco set builds from the tree; `make check` generates every generated file into the build tree from checked-in inputs, and fails on a generated file found in the tree | 4,000 lines of Ruby | | G0 |
| M1 The system boots on Fiasco | the near-stock Fiasco prints erXos's banner and starts `liberx`'s root entry as the root task under HVF; the production image boots to the point where ERTS starts | 3,000 to 4,500 lines of C17 | M0, G0 | |
| Track H Hosted mode | the runtime runs as a Mac process under the sanitizers; once a consumer needs the sanitizers or `lldb` across domains, domains and their connections run as Mac processes too, over the same backend rows as Fiasco's | 3,000 lines of C17 | M0 | |
| M3 The shell is the operating system | `1>` on the serial console, from ERTS in the system domain in user mode, started by the root task | 8,000 lines of C, 1,000 of Erlang | M1, track H | G3 |
| M4 The machine is an object | save in the editor on the Mac, run in the machine; follow a process to its source; ERTS and backend events on one timeline, the kernel's row unsupported | 10,000 lines of Erlang, 3,000 of Ruby, 2,000 of C | M3 | |
| M6 Immutable code, lasting data | the shell reads a file of the slot's system partition through the `system` tree on a QEMU disk; a file under `/data` survives a power cut | estimated in the subsystems' design documents | M4 | |
| Track S The command shell | `ps -m \| grep erx` in a shell with rc's language, printing FreeBSD's text | 6,000 lines of Erlang, 4,000 of C17 for the track, programs included | M4 | |
| **Phase 1b** | | | | |
| 1b-A M5 on Fiasco | spawn into a sandbox domain with a link, crash it, get `{domain_down, D, crash}`; kill a domain mid-burst and watch its end arrive after its last messages; kill the system domain and read its crash record after the reset; every guarantee deferred | 9,000 lines of C17, 6,000 of Erlang for M5, its kernel interface carried as backend rows in the Fiasco backend, and in the hosted backend where cheap (2,000 to 4,000 lines of C17, a guess until the first rows land) | Phase 1 | G5, provisionally |
| 1b-B Track S, programs | `find /tmp/logs -type f \| xargs tail -n 1` through toybox's applets as ports of the session, and `within` confining a program to one grant, on Fiasco | in track S's figure | 1b-A | |
| Track A Apps, part 1 | a QEMU image boots into an app's session with no login, holding exactly its template's grants, and `service -e` prints everything that starts | estimated before it starts | 1b-A, 1b-B's session domain, and M6's data partition for `start.conf` | |
| 1b-C Track D, parts 1 to 4 | `tools/erx web` shows a QEMU guest's records, kernel log and the traces of `root`'s session domain in a browser over the host link, with no network or display device; one application's user interface in the browser; a QEMU `virt` display showing the window of a session that starts at boot with no login, drawn by that session into a buffer the display domain composes; and the same interface on a QEMU `virt` kiosk, drawn by LVGL as a program of the kiosk's session | estimated per part before it starts; the designs give no figure | 1b-A and the session domain, 1b-B's first slice; part 3 also 1b-E and track A's first part; part 4b also 1b-B's sub-space ports and pipes, 1b-D's first slice and track A's second part | GW |
| 1b-D Track P, the first part | a UNIX program recompiled unchanged makes pipes, spawns children with inherited descriptors and waits for them, on Fiasco | 10,000 to 15,000 lines of C for the track | 1b-B's session domain, sub-space ports and pipes, not toybox's applets | GP, provisionally; the G6 baseline |
| 1b-E M9 on Fiasco | a block transfer runs while the block driver process is killed; the kill ends the storage domain, whose restart resets the device and mounts `/data` again with every synced file present ([design-stopgap.md](design-stopgap.md#littlefs-in-the-storage-domain)); drivers run in the storage and network domains over virtio-mmio, unconfined | 3,000 lines of C17, 5,000 of Erlang for M9, of which the PCIe enumerator and the MSI frame's driver are its kernel part's | 1b-A | G9's measurements, deciding nothing |
| Track A, part 2 | an app built outside the tree with the SDK alone, added to an image with `tools/erx pack --app`, boots into its session with exactly the `apps` row's services its declaration names, its code read from its package at `/app` | estimated before it starts | part 1 | |
| Track A, part 3 | the same package copied into `/apps` on a running machine is admitted there, its image readable through `mount`, starts at `service NAME start` once enabled, survives a reboot, and is removed with `rm`, its data kept | estimated before it starts | part 2, M6's data partition and 1b-E | |
| 1b-F Track D, parts 6 to 8 | a QEMU `virt` desktop whose terminal windows run the shell, the same user interface term as on the web, and erXos's own `stats`, `clock`, `month` and `files` in one theme | estimated per part before it starts | 1b-C's part 3 | |
| 1b-G Networking on QEMU | the network domain carries UDP echo and a TCP bulk transfer to a Linux peer through the packet-path prototype, on QEMU under HVF | estimated in the network service's design document | Phase 1: the network driver and stack run in the system domain, as M6's block driver does, until 1b-E moves them into the network domain | GN-QEMU's baseline, deciding nothing |
| M14 erXos's network stack, on QEMU | TLS, SSH and distribution sessions run over erXos's own TCP/IP stack, written in Erlang from FreeBSD's, on QEMU in 1b-G; the boards follow with M12 | estimated in its design document | 1b-G's prototype | G14 |
| 1b-H M13 erXos's F2FS on QEMU | erXos's F2FS, written in Erlang, keeps a QEMU disk's files through power cuts and its images mount in the Linux guest; on the Pi 4 with M12 | 8,000 lines of Erlang, 2,000 of Ruby, 5,000 of tests ([M13](#m13-erxoss-f2fs)) | M6 | G13 |
| 1b-I The Raspberry Pi 4 on Fiasco | the Pi 4 boots from its firmware to the shell on its console; a file synced on its SD card survives a power cut; its Ethernet carries UDP echo and a TCP transfer; the kiosk shows on its screen; a clock module on its header keeps the time across a power cut; every guarantee deferred | estimated per part before it starts; the designs give no figure | part (a): Phase 1; (b): 1b-E; (c): 1b-E and 1b-G; (d): 1b-C's part 3; (e): (a) and 1b-E | GR |
| 1b-J The Raspberry Pi 5 on Fiasco | the Pi 5 boots from its firmware to the shell on its debug UART; its Ethernet carries UDP echo and a TCP transfer through RP1; a USB keyboard and stick work on RP1's hosts; every guarantee deferred | estimated per part before it starts; the designs give no figure | (a), (b): 1b-I's part (a); (c): 1b-I's part (b); (d): 1b-E; (f): 1b-G; (g): 1b-C's part 3; (h): Track U's part (a) | GR5 |
| 0.1 The preview, erXos's first public preview | a development build's published card boots a Raspberry Pi 4 to the kiosk with live quotes on its screen, root reaches `rc` over SSH with the key on the card's record partition, sets the clock and runs `ps` and `top`, `/data` survives a power cut and a fault or a hang resets the board; the QEMU image of the same build does the same, and Doom, in both images, plays on QEMU with the virtio keyboard and runs its demo loop on the Pi | the clean-room interface header (its images keep the kernel debugger by decision, with its source offered; leaving it out is 0.2's release kernel's), the end path's reset, the hardware watchdog on every boot, the set-time command and the login key's reader, each estimated before it starts; the milestones it takes carry their own figures | [0.1's dependencies](#01-the-preview) | |
| 0.2 The first release, on Fiasco | a release build on QEMU `virt` and the Raspberry Pi 4 boots without the development banner, asks for a login and runs an installed app whose code is untrusted, which reaches no other domain, stops at its memory wall and spins in its own band without delaying the display or a driver; the release notes carry the downsides against erXos's kernel | the backend on Fiasco's own mechanisms and four Fiasco patches (the clean-room interface header, the release kernel's build without `jdb_object.cpp`, writable or executable, eager FP switching), five if the null-request bench shows that FD32's hardening of its entry costs nothing measurable, estimated before it starts; the milestones it takes carry their own figures | 0.1, Phase 1b and track A, and the Fiasco forms of M9's kernel part's devices, the rest of track P, M10, M12, track D's parts 5 and 9 and M11's closure | the gates of the milestones it takes: GP, G12, GN-board |
| Track F Fiasco, improved to the decision | a closed IRQ handle whose slot was reused answers `ERX_ESTALE`; a debugger stops, reads and resumes a thread; a domain spinning in its band gets no more than its grant; a program borrows memory its session has free; a copy-on-write `fork` or a shared file mapping works on Fiasco through the root as pager; each stage removes or narrows its rows of the downsides | about 7,000 to 16,000 lines of C17 and C++ in the fork, the backend and the root, the scheduler stages' 2,000 to 4,050 among them (unverified estimates, none prototyped; [design-fiasco.md](design-fiasco.md#stages-beyond-bands)) | 0.2 | each stage by its tests, the scheduler stages by their before-and-after numbers on Fiasco over the workloads G8 names (E-S1, E-S3 to E-S9); then GF |
| **Phase 2, if gate GF chooses erXos's kernel** | | | | |
| Track K erXos's kernel | the pilot, then the kernel, booting 0.2's boot image and passing the conformance suite | 25,000 to 40,000 lines of C17, of which the capability core and the budget core exist; the pilot calibrates the figure | the pilot: M0, starting before Phase 1 is complete; the kernel in full: 1b-A and gate GF | GK1, GK2, GK3 |
| M7 Fiasco leaves | erXos's kernel boots 0.2's system and runs every test and benchmark it ran on Fiasco | integration | track K, 0.2 | GK3 |
| M2 The execution contract holds | a native test domain and a hostile domain share four CPUs by grants; no wakeup is lost; a blocking call from an executor is refused | 4,000 lines of C17 | M7 | G2 |
| M5's kernel part | a hostile runtime attacks a neighbour's funnel for ten minutes without effect; a domain killed under load gives every charge back to its principal's budget | in track K's figure | M2 | G5, confirmed |
| M9's kernel part | the drivers' restarts over virtio-pci with MSIs, each device's DMA confined behind the IOMMU, and the PCIe domain alone reaching configuration space | the PCIe enumerator and the MSI frame's driver, within M9's figure | M7 | G9, then G6 |
| Track P, the rest | a UNIX program recompiled unchanged pipes, polls, spawns children and takes `SIGINT` | in track P's figure | track P's first part; Fiasco's vCPU row | GP |
| M8 Cooperation earns its place | the ladder from plain threads to full cooperation, measured on seven workloads, with each feature kept or dropped by its numbers | 4,000 lines of C17 and C | G6 | G8 |
| M10 Users without a container runtime | two users, two domains, one runs out of memory or CPU alone | 4,000 lines of Erlang | M8, M9's kernel part | |
| Track Q The second tier | toybox's `sh` runs a script with subshells and `less` pages a log in a terminal session, and a dynamically linked program loads a library with `dlopen` | the programs' estimate in [design-programs.md](design-programs.md#performance), and the session's shared mappings, an estimated 3,000 lines of Erlang; the kernel's part is track K's, or on Fiasco the root's pager of track F's F7 | track P; its first consumer on Fiasco with F7; the rest M7, or the course gate GF sets | GQ |
| M11 Security closure | a release build without the development banner, on erXos's kernel, with an Erlang driver behind an IOMMU window; one flipped byte of an EROFS image reads `eio` | hardening | M10 | |
| M12 Storage, networking, boards | a Raspberry Pi 4 boots erXos from its SD card, keeps its files through power cuts, and takes a system update whose trial survives a power cut | estimated in the subsystems' design documents | M11 | G12, GN-board |
| Track D, parts 5 and 9 | a Raspberry Pi 4 kiosk; the web front end on the network | estimated per part before it starts | part 5: part 4 and M12; part 9: part 2, M10, M11 and 1b-G | GD, with part 5 |

The order reaches a usable system first:

* Phase 1 boots Fiasco near-stock and puts `liberx`'s backend on its
  calls, in increments a transcript test checks each: boot, memory,
  threads, a second task, an interrupt, the production image.
* The shell runs on ERTS with only the changes it cannot run without,
  hosted first; the live machine follows at once, because it is the
  product's identity and the instrument every later milestone is debugged
  with; then files from EROFS and littlefs, and the Erlang command shell.
* Phase 1b stands further on Fiasco, so that every item is a demo a
  person can watch before erXos's kernel exists. The order puts the
  demos a person sees soonest first. Domains over connections come first
  (1b-A), since every later item is a domain or runs in one; then
  1b-B's first slice, the session domain; then drivers in their own
  domains (1b-E), with the storage domain, and networking on QEMU
  (1b-G), which starts at once in the system domain, as M6's block
  driver did, and moves into the network domain with 1b-E; then the
  web on the developer's host over the host link, which needs no device
  on the machine (1b-C's parts 1 and 2); then the window stack on QEMU
  `virt` (1b-C's part 3), a session's window composed by the display
  domain. Programs as ports of their sessions over pipes and the first
  part of the POSIX personality (1b-D) follow, and on its first slice the
  kiosk on QEMU `virt` drawn by LVGL (1b-C's part 4), whose LVGL program
  is a program of the kiosk's session; toybox's applets, the
  rest of 1b-B, come after 1b-D; gate G6's baseline records the result on
  Fiasco and decides nothing. The desktop with terminal windows (1b-F)
  comes after all of these, and last the boards' panels and the network
  front end. The backend grows the rows these need behind the unchanged
  interface, and the guarantees they would rest on are recorded as
  residuals, not built.
* Beside that path: BeamAsm beside 1b-A, and erXos's F2FS on QEMU (1b-H)
  at the lowest priority, whenever capacity is idle. The Raspberry Pi 4
  on Fiasco (1b-I) starts its serial shell on QEMU's `raspi4b` model
  once Phase 1 is done, passes it once on the board by hand, and
  brings each later stage to the board once the
  QEMU item it rests on has landed: storage after 1b-E, the network after
  1b-G, the display after 1b-C's part 3. The network stack's
  host-first packages run beside everything, since they need no guest.
* 0.1, the preview, is Phase 1b's first published result: a
  development build whose closure is distributable, with the clean-room
  header brought forward from 0.2 and the kernel debugger kept, its
  source offered ([0.1](#01-the-preview)). The work is ordered towards
  0.2.
* 0.2 ships that system as erXos's first full release on Fiasco: the backend
  moves onto Fiasco's own capabilities, factories, interrupts and DMA
  spaces, the release build drops the debugger and the GPL files, and
  the security closure is reached in its Fiasco form. It also takes,
  in their Fiasco form, the user-facing milestones that would otherwise
  wait for erXos's kernel: M9's devices, the rest of track P, M10, M12
  and track D's parts 5 and 9; track Q follows 0.2. It ships two
  stopgaps, littlefs and LVGL, each under its release contract.
* Track F follows 0.2: the contained fixes of Fiasco and the root,
  Fiasco's scheduler stages, budgets with caps and a pager in the root
  under track Q's first consumer, each stage removing or narrowing rows
  of the downsides. Gate GF then weighs the rows left, what each costs
  to close on Fiasco and what erXos's kernel still costs, and decides
  whether erXos builds its own kernel.
* Track K's pilot starts before Phase 1 is complete and runs beside
  Phase 1b, and its C17 cores continue whatever GF decides, since
  Fiasco links them; erXos's kernel in full follows 1b-A and gate GF,
  if GF chooses it, written from its design documents, which neither
  phase changes.
  It boots the same boot image and switches at parity over 0.2's
  system (M7); the execution contract (M2), the kernel parts of M5
  and M9 and gate G6 then land on it, and G6 measures the result before
  anything more is built on it.
* Everything after that lands the same way: the cooperation features,
  users, the second tier, the security closure, and then the boards with
  their storage and networking; where 0.2 took a milestone's Fiasco form,
  what lands on erXos's kernel is that milestone's criteria that need it.
* Storage on the boards stands on littlefs first, which 0.2 ships under
  its release contract
  ([design-stopgap.md](design-stopgap.md#release-contract)); erXos's
  F2FS, written in Erlang, replaces it at parity, decided on QEMU in 1b-H. Networking has
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

In Phase 1b, after track S's shell, on Fiasco, build the domain and
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
  back in its principal's budget, checked at M7 and on Fiasco through
  the budget's partial `used`, without losing the system shell;
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
| GP, programs and pipes | track P, in hosted mode first and under HVF on Fiasco before the first part of track P is complete; Fiasco's numbers are provisional, since each object a program's start makes is one request to the backend's root service there | a program's start from the session's `spawn` to its `main` (`tools/erx bench spawn`) against the budget of [design-programs.md](design-programs.md#performance) and against `posix_spawn` on Linux in a guest; a `make`-shaped workload of many short children over pipes with a paused pager, and `tools/erx bench pipe` with one writer and with 256 writers; latency, throughput, memory per program and per pipe, and the session's Erlang work per request | the channel's and the data area's defaults, completion batching in the handler, whether the pipe server keeps one ring per write end ([design-pipes.md](design-pipes.md#the-ring)); whether a program's start needs a cheaper path than one kernel call per object is decided at GK3, on erXos's kernel |

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
| First generated service interface and the rest of the startup descriptors | 1b-A | console/service operations generate C/Erlang clients, admission/dispatch and bounded replies with scope policy in the handler; source checks refuse bypasses; the checked manifest's packed descriptors supply boot order, configured domains' devices, configured facets and watchdog liveness |
| Cross-domain service and protocol consumers | 1b-A and each later service | generated serving paths authenticate lane origin, check the live facet scope and bound input/output before callbacks; hostile tests exercise forged origins, stale handles, denied targets and restricted inspection fields; the 9P profile keeps its independent standard oracle |
| Command catalogs | track S | release metadata generates names, help and required facets, checked against callbacks without running target code; tests preserve name conflicts/precedence and bind metadata to loaded code across replacement and publication failures; a catalog grants no authority |
| Contextual error mappings and program interfaces | track P | generated translations cover every exposed status/error in its operation context, and fault/signal mappings cover every fault; compare numbers against FreeBSD's headers and behaviour against the selected musl/OTP and protocol oracles; raw kernel-call stubs still return status without setting errno |
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

**Exit.** `make check` passes offline after `make fetch`: OTP 29.1.2,
musl 1.2.6 and the frozen Fiasco set live in the tree with their
`ORIGIN.md` files, the oracle runs stock OTP 29.1.2 cases in its
[offline Linux context](design-host-oracle.md), the QEMU harness boots
the near-stock Fiasco to its banner under both accelerators, the TLC
runner stands behind `make check-tla`, and every generated file is
generated into the build tree from its checked-in inputs.

**Gate G0.** The import: the license scan and link closure of the Fiasco
set, which name the GPL-headed files Fiasco keeps
([design.md](design.md#dependencies)); since every build includes
`kobject_rpc.h`, whose Fiasco original is GPL-2.0, any distribution
outside the project, in source or binary form, rests on the MIT
clean-room header that takes its place in the tree, brought forward
from 0.2's release build
([design-fiasco.md](design-fiasco.md#the-releases-fiasco-build)), as
CLAUDE.md's rule for release components requires. The kernel debugger's
`jdb_object.cpp`, which a kernel with the debugger compiles, goes out
only in 0.1's images, under CLAUDE.md's exception for the website's
images with its source offered; the release kernel leaves it out.
`lld` installed.

## M1: The system boots on Fiasco

**Exit.** A near-stock Fiasco boots erXos's boot image and starts
`liberx`'s root entry as the root task, and `liberx`'s Fiasco backend
gives, over Fiasco's own calls in user mode, every function that ERTS,
musl, the device NIF and the test tasks need, each with a test that the
hosted backend passes with the same result, refusals included
([design-fiasco.md](design-fiasco.md)); a stopped pet, a fault of the
root and a touch of a decommitted page each end the machine with a crash
record whose cause names them, while a fault in a test task ends only that
task. Until track K brings `erx_root_plan` with its charge evidence, the
Phase 1 manifest check's root startup rule stands in for the initial
root's feasibility and charge plan
([design-fiasco.md](design-fiasco.md#the-phase-1-manifest-check)).

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
and park and wake, under HVF; and E-S4's FIFO wake latency. Fiasco's
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

`liberx`'s hosted backend implements the kernel interface inside a macOS
process: spaces are the process, threads are pthreads, memory objects are
`mmap`ped regions, umtx waits are `os_sync_wait_on_address`, and groups and
parking keep the epoch protocol
([design-runtime.md](design-runtime.md#liberx)). From M3 on, ERTS's port
runs hosted first, under ASan, UBSan and TSan, and `lldb`. 1b-A targets QEMU: through 1b-A the hosted backend stays one
process, and gains the rows 1b-A needs only where they are cheap there.
Its multi-process form, in which several domains run as Mac processes with
their lanes in shared regions and the domain library drives the hosted
interface, is deferred until a consumer needs the sanitizers or `lldb`
across domains; no part of the plan waits for it, and the Bluetooth
suites, its first candidate, run on QEMU `virt` instead
([Track B](#track-b-bluetooth)). When it comes it carries the Fiasco
backend's rows between tasks and no device row, since a hosted runtime has
no devices, and gets its design, reviewed as a design, before its code
([design-fiasco.md](design-fiasco.md#the-hosted-backend)). It is a
planned feature in [TODO.md](../TODO.md). QEMU remains authoritative.

## M3: The shell is the operating system

**Exit.** ERTS runs as the system domain in user mode, started by the
root task, to `1>` on the serial console; OTP's `emulator`, `kernel`,
`stdlib` and `compiler` suites run there under stock Common Test and are
compared case by case with stock OTP 29.1.2, every difference fixed,
explained or in `TODO.md`, and every case that cannot run yet shown with
its reason.

**Gate G3.** Measures: W1 of E-S1 (same-domain ping-pong and ring, spawn,
switch) against stock OTP 29.1.2 on the host, under HVF; footprint; boot
time to the shell. Decides: the baseline every later change is measured
against. Under TCG the guest's numbers are recorded alone, since TCG
numbers are never set against native ones
([design-bench.md](design-bench.md#fixing-the-existing-tools)).
The first run, taken at a high load average and so not yet a valid
baseline, is in [research-g3-baseline.md](research-g3-baseline.md);
`tools/erx bench g3 --accel hvf|tcg` measures it again.

## M4: The machine is an object

**Exit.** The live machine: `erx watch` on the Mac hot-loads a changed
module into the running system domain through the install facet;
`erx:i()`, `erx:source(Pid)` and `/proc` show the machine with each
value's reporter; `erx:trace` puts ERTS's and the backend's events on
one timeline; and every value only the kernel could report reads
`unsupported` ([design-live.md](design-live.md)).

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
On Fiasco (1b-A) the demo runs without the budget's return, the
grants and the hostile runtime, which M5's kernel part adds.

**Scope.**

* **The log sink** in every domain, before any other domain's text can
  reach a log ([design-live.md](design-live.md#the-console)).
* **Connections and lanes**, with the wake handshake by published
  positions ([design-domains.md](design-domains.md#connections)).
* **The funnel**, one C17 library in `liberx` linked by every runtime,
  with the chokepoint check that only `erx_lane_take` reads a lane's pages
  ([design-domains.md](design-domains.md#the-funnel)).
* **The peer in ERTS**: every domain a node under stock distribution, one
  distribution entry per connection, and the export table with its
  writers ([design-runtime.md](design-runtime.md#connections-in-erts),
  [design-domains.md](design-domains.md#exports)).
* **Tracing across domains**: the trace facet, the trace relay in each
  traced domain and tracing of cross-domain frames
  ([design-live.md](design-live.md#tracing)).
* **The domain library and the system services**: the creation plan with
  undo, end classification and `{domain_down, D, Info}`, a connection's
  objects deleted only once each party has unmapped them or ended and
  never on a timer while a party lives, and the ordered end of the
  machine; the domain service with introductions, facets and domain ids
  never reused within a boot; namespaces for every domain; and the system
  domain loading only code from its release slice and its install arena
  ([design-domains.md](design-domains.md#connections),
  [design-system.md](design-system.md#the-domain-library),
  [design-files.md](design-files.md),
  [design-runtime.md](design-runtime.md#code-in-the-system-domain)).
* **BeamAsm** in the runtime image for ordinary domains; the system
  domain runs the interpreter image and holds no JIT object
  ([design-runtime.md](design-runtime.md#beamasm)).
* **The kernel interface sub-spaces and programs need** (capability
  passing, deleted memory whose mappings fault, `erx_mem_copy`, space
  parents with stop propagation, sub-space creation by a domain allowed
  `SPACES`, and vCPU upcalls), on erXos's kernel with its conformance
  tests, as M5's kernel part
  ([design-kernel.md](design-kernel.md#passing-capabilities),
  [design-kernel.md](design-kernel.md#closing-and-deleting),
  [design-kernel.md](design-kernel.md#creating-spaces),
  [design-kernel.md](design-kernel.md#vcpu-upcalls),
  [Track K](#track-k-erxoss-kernel)).
* **Tests**: the funnel's fuzz target and its differential test against
  `binary_to_term/1`; the fuzz targets of the lane reader, `erx_etf`, the
  system domain's safe decode and the facets' generated admission; the
  hostile-runtime suite at the receiving funnel
  ([design-domains.md](design-domains.md#verification-and-testing)); the
  root task's end tests
  ([design-system.md](design-system.md#verification-and-testing)).

**On Fiasco (1b-A).** Every bullet of the scope lands on Fiasco except
tracing across domains and the kernel interface sub-spaces and programs
need, which are M5's kernel part, after M2; until then the trace view of
[track D](#track-d-windows-widgets-and-the-web)'s part 1 traces its
session's own domain. On Fiasco that interface's consumers use rows the
Fiasco backend adds behind the unchanged interface, the creations and
passes among them called from the root, where the domain library runs
([design-fiasco.md](design-fiasco.md#the-call-table)); the hosted backend,
one process through 1b-A, adds them only where they are cheap
([track H](#track-h-hosted-mode)). Sub-spaces created at a task's
request, creation and passing from a task other than the root, and paged
objects, sealing, supply and `ERX_MEM_CODE` come with 1b-B, whose
sessions are their first consumer
([track S](#track-s-the-command-shell-and-toybox)); device objects given
to a holder domain come with 1b-E ([M9](#m9-a-driver-is-an-erlang-process));
whether vCPU upcalls get a row is settled before 1b-D
([track P](#track-p-the-posix-lite-personality)). Passing at a
rendezvous, pauses, IPC gates above `liberx` and every budget and grant
enforcement stay refused, each a recorded residual. The funnel's verdicts
run unchanged in user mode; what Fiasco cannot promise is that a domain
which bypasses `liberx` is stopped by anything
([design-domains.md](design-domains.md#on-fiasco)). BeamAsm lands beside
1b-A, off its critical path, since it needs nothing of the kernel. The
hostile suites' verdict cases, a funnel's answer to a malformed or forged
frame, are written in 1b-A and run and count on Fiasco; the cases that
check a bound on memory, CPU or a neighbour's latency, the budget
criteria and every case against a domain that bypasses `liberx` are
written at M5's kernel part and run on erXos's kernel alone
([design-fiasco.md](design-fiasco.md#what-phase-1-code-must-not-assume)).

**Exit criteria, on Fiasco (1b-A).** The two-node differential
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
of Fiasco's list passes again, by M7's parity; the kernel interface
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
1b-A, on Fiasco, it measures what is user-mode cost: E-D1 and E-D2,
with `tools/erx bench xdomain-pingpong` and `xdomain-throughput`, and, in
an ordinary domain, BeamAsm's speedup over the interpreter on OTP's
benchmarks and on the oracle's suites, the footprint of a domain in each
flavour and the time to translate a release when the domain starts. It
decides provisionally: the default table sizes of the runtimes and the
domain service, a domain's `cap_limit` among them, and not
Fiasco's own fixed limits; the defaults of `lane` and
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
measurements on Fiasco, and decides the death path's batching and the
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
1b-A, on Fiasco, as 1b-B, whose first slice is the session domain; the
job control of programs follows M7, on erXos's kernel. littlefs runs as a
NIF in the storage domain that 1b-E configures; its sub-space port follows
once this track's port driver exists, and from then a crash injected into
littlefs mid-write ends only that port, whose owner restarts it and
remounts the volume with no acknowledged write lost. On Fiasco a
program's budget and group are unenforced records, and the backend gains
here the rows a session is the first to call
([design-fiasco.md](design-fiasco.md#the-call-table)). The narrowing of
`within` is the handler's table and the servers' grants, user mode, and
holds there, while that a program cannot escape `liberx` does not
([design-programs.md](design-programs.md#a-program-is-a-port)):

* the shell in Erlang, with the parser's fuzz target, and plan9port's rc
  built from its pinned source as the oracle, with the corpus from
  `test.rc`, the parser checks and `trip.rc` ([design-shell.md](design-shell.md));
* the session domain, which the domain service starts for a console
  line's login and the host link's, in a development build `root`'s, with
  the shell and its command server in it; the logins of other principals
  follow in M10
  ([design-domains.md](design-domains.md#principals-sessions-and-quotas));
* programs as ports of the session, over the sub-spaces 1b-B brings: the
  port driver `erx_program`, the command server and a handler per program,
  the channel protocol and the startup message with their fuzz targets,
  the descriptor table, spawn and wait
  ([design-runtime.md](design-runtime.md#programs-as-ports),
  [design-programs.md](design-programs.md#a-program-is-a-port),
  [design-programs.md](design-programs.md#the-handler)); the session's
  terminal relay with the line discipline `erx_tty`, its exhaustive model
  and its fuzz target, and `erx_output`
  ([design-live.md](design-live.md#the-tty),
  [design-runtime.md](design-runtime.md#the-console-and-standard-io));
  the session's pipe server and the pipe NIF
  ([design-pipes.md](design-pipes.md)); executables run from the EROFS
  images through the sealed file objects a program's session maps
  ([design-programs.md](design-programs.md#what-a-program-can-start));
* the job control of programs, over the pauses of track K's
  after-the-switch increment;
* `rc` running programs in pipelines (`prog | wc`), after the pipes among
  programs, which are first tested from Erlang
  ([design-shell.md](design-shell.md#pipelines));
* toybox 0.8.15 and `wak` imported as erXos's code and built applet by
  applet, each with toybox's own tests in a test domain;
* evi, the screen editor, run as `vi` ([design-vi.md](design-vi.md)), an
  estimated 2,500 lines of Erlang: it follows the session domain and its
  terminal relay and needs no program, pipe or toybox applet, so it lands
  before them, and brings the command shell's terminal calls
  ([design-shell.md](design-shell.md#interfaces)).

**Exit criteria, the shell (Phase 1).** The shell's corpus agrees with
plan9port's rc, every difference classified and pinned by a test; job
control pauses, resumes and ends jobs of Erlang commands three generations
deep; the parser and `grep`'s pattern translator run their fuzz budgets
clean; `ps`, `ls`, `grep`, `sort` and `wc` agree with FreeBSD 15.1's over
their corpus in the oracle guest, every difference classified and pinned
by a test.

**Exit criteria, evi (1b-B).** In a session over the host link's
`console` line, `vi` edits a file, writes it with `:wq` and leaves the
prompt editing as before and the next command of its line cooked; it
follows a size change, stops on `^Z` and redraws after `fg`, and draws
nothing in the background; a `vi` killed mid-edit leaves the prompt
working; and it edits an 8 MiB file to its held-text budget under its
16 MiB heap. Its key-script
corpus writes the same files as nvi on the FreeBSD 15.1 oracle guest,
every difference listed in [design-vi.md](design-vi.md) and pinned by a
test; its key parser passes its exhaustive test; its output check finds
only printable text and its own sequences over the fuzz corpus; and its
three fuzz targets run their budgets clean.

**Exit criteria, programs (1b-B).** Toybox's tests pass for every
applet built, or each failure is classified; a pipe's end of stream
arrives only after its last writer goes and every byte written has been
read, a writer that faults included, and a program's end reaches its
port's owner as `{exit_status, N}` after its last bytes; a domain's
sub-spaces, a session's programs among them, end with it; a pipe with a
paused reader and sixty-four writers still spawns its sixty-fifth, which
blocks on its write, never on its spawn (on Fiasco the check runs at
the smaller of the two bounds on a session's writers, 64 IRQ objects a
group, about 30 writers in practice, and the gate worker's 32 programs at
once, and the check at 31 writers and above runs on erXos's kernel, as
M7's checks below do; both bounds are residuals in
[TODO.md](../TODO.md)); job control pauses, resumes and
ends jobs of programs, checked at M7, which brings the pauses; all 256
byte values and every control sequence a program writes reach the
console exact (V1); a narrowed program that tries every command name
reaches nothing outside its grants, and a program holds no grant's pid
and reaches nothing but its channel and the memory its session mapped
(SH1 of [design-shell.md](design-shell.md#invariants), P2 of
[design-programs.md](design-programs.md#invariants)), checked through
`liberx` on Fiasco and, against a program that bypasses `liberx`,
with its budget and grant enforced, at M7; passed files share their
offsets; the startup message and the channel protocol run their fuzz budgets
clean.

**Gate G6 baseline, at the end of 1b-D.** Records, on Fiasco, under
HVF and TCG apart, the memory of an idle domain of each kind, an ERTS
domain and a native test domain, of a session with its shell and of one
program as a sub-space, what the session's own services use, and a
facet's heap; E-D1's round trips and E-D2's draining under many
connections; and `tools/erx bench fs` from a program and from an Erlang
process and `tools/erx bench blk`, against M6's baseline. It decides
nothing: Fiasco enforces no budget, so a budget settled on its
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
over the vCPU upcalls of Fiasco's vCPU row or of M7, triggered by the
session's port driver
([design-programs.md](design-programs.md#signals-in-liberx)), with
`erx_sig_step` explored on the host; the generated `errno`, signal and fault
tables; `erx_exec` and `erx_elf_plan` with its fuzz target, and `rx` grants
with the `exec` open; `rc` in program mode, and `system` and `popen` over
it; the Open POSIX Test Suite as an external test tool in a test domain.
Its first part, descriptors with `dup` and `fcntl`, `pipe`, `posix_spawn`
with inherited descriptors and file actions, `wait` and `kill`, and
`erx_exec` with `rx` grants, is 1b-D: it follows track S's programs, on
Fiasco, and ends with the G6 baseline. The rest follows. `kill` and
catchable signals run on Fiasco, through the backend's vCPU row over
Fiasco's vCPU upcall
([design-fiasco.md](design-fiasco.md#vcpu-upcalls-on-fiasco)).

**Exit criteria, the first part (1b-D).** Descriptors, `dup`, `fcntl`,
`pipe`, `posix_spawn` with inherited descriptors and file actions, `wait`
and `kill` pass their cases of `libc-test` and the Open POSIX Test Suite,
every other failure among them classified; without Fiasco's vCPU
row, a case that needs a signal handler shows as "cannot run" with that
reason and runs at M7, and `sigaction` with a handler fails with
`EINVAL`; with the row, the vCPU conformance tests of M5's kernel part
pass on Fiasco; a pipe's bytes stay readable
after their writer ends; a crash of the session's pipe server makes reads
fail with `EIO` and writes with `EPIPE`, never a false end of stream; an
executable runs through an `rx` grant and is refused through `ro` and
`rw` ones; `erx_elf_plan` and the startup message's decoders run their
fuzz budgets clean.

**Exit criteria, the track.** Those of the first part other than its
cases without Fiasco's vCPU row, and: musl's
`libc-test` and the Open POSIX Test Suite pass, every case that needs
`fork` or a facility the personality lacks recorded as unsupported and
every other failure classified; a signal sent while the main thread
computes, runs inside `liberx`, waits on a umtx word, waits for a reply,
is in a call on its channel or is about to sleep is delivered each time,
the call's case once the call returns, and its handler's return restores
the thread exactly; a file write interrupted by a handler returns its
count; `poll` over 500 pipe ends reports exactly the ready ones; `system`
and `popen` return the wait statuses of `rc`'s `$status`.

**Gate GP.** As [Simplification experiments](#simplification-experiments)
states it.

## Track D: Windows, widgets and the web

**Goal.** A browser, a kiosk and a desktop on QEMU `virt`, and a panel
on a board, as displays of the running system: one widget interface on
all of them, served in the application's own session; every window a
buffer its client draws and the display composes; terminals as programs
of the user's session; and typed values as presentations
([design-display.md](design-display.md), [design-web.md](design-web.md)).

**Demo.** On the Mac, `tools/erx web` shows in a browser the inspector's
records, `/proc`, the kernel log and a trace of a QEMU guest that has no
network and no display device, every typed value a link; an Erlang
application opens a user interface term on the `web` display; a QEMU
`virt` display shows the window of a session that starts at boot with no
login, drawn by an Erlang process of that session into a buffer the
display domain composes; the same application then runs as a kiosk,
whose session draws the same term with LVGL as one of its programs; a
desktop follows, where a terminal window runs the shell
with job control and a click on a pid that `ps` printed in that terminal
inserts it into the command line; a Raspberry Pi 4 kiosk boots into one
full-screen application, takes touch input and turns its panel off when
idle.

**Scope.** Ten parts, each ending in its own exit criteria. The first
slice needs no device: a browser on the developer's host over the host
link, which every QEMU guest already has. The window stack comes next,
since the kiosk and the desktop are both its clients: a kiosk is the
single policy and an app that a start row starts, a desktop the
overlapping policy and a person's session that a start row starts
([design-display.md](design-display.md#overview),
[design-apps.md](design-apps.md#the-start-table)). The kiosk
under LVGL follows the window stack and the first slice of track P,
since the LVGL program is a program of the kiosk's session over the
session's pipes; the desktop needs neither LVGL nor track P. The pure
cores the parts use (the widget tree's validator and difference, the web
protocol's codecs, the screen's composition and its policies,
`erx_memdraw` checked against 9front's `libmemdraw`, the draw protocol's
core and codecs, the terminal's state machine and the desktop programs'
cores) build for the host and are written and tested there, with their
fuzz targets, ahead of the part that integrates them
([design-display.md](design-display.md#verification-and-testing)).

In this track W1 to W8 name design-web's invariants and G1 to G10
design-display's, not the plan's gates or E-S1's workloads. Parts that
land after M11 repeat M11's closure over what they add.

1. **The web over the host link**, as 1b-C, after 1b-A, which brings the
   domain service, and the session domain, 1b-B's first slice, which
   brings `root`'s session domain, the session a browser's views run in;
   nothing in it needs the kernel. The web domain, the session's line,
   the host link's `web` facet bound to `root`'s session, `tools/erx web`
   and the client under `web/`, built by `make web` offline
   ([design-web.md](design-web.md#the-host-tools-front-end)). A trace view
   traces the session's own domain alone until M5's kernel part brings
   tracing across domains ([M5](#m5-a-wall-around-some-processes)); the
   manifest check's refusal of the `web` facet in a release manifest comes
   with [M11](#m11-security-closure).
2. **Widgets on the web**, in 1b-C, after part 1: `erx_ui` with its widget
   server in the application's own session, and the browser renderer
   ([design-web.md](design-web.md#uis-the-browser-renderer),
   [design-display.md](design-display.md#choosing-a-display)). Its tests
   check the browser renderer alone; its parity test with LVGL comes with
   part 4, and with the Erlang renderer with part 7.
3. **The window stack on QEMU `virt`**, in 1b-C, after the session domain,
   track A's first part and 1b-E, in which a configured domain other than
   the system domain is given its devices at its creation; it needs
   neither part 2 nor a native program. The pixel area, the display domain
   with its virtio-gpu and virtio-input drivers in Erlang, the window
   tree, the client library `erx_win`, and the display's session, which a
   start row starts at boot
   ([design-display.md](design-display.md#the-pixel-area),
   [design-display.md](design-display.md#the-screen-and-its-one-path-to-the-device),
   [design-display.md](design-display.md#a-displays-session)). The
   devices attach over virtio-mmio on Fiasco, unconfined, and over
   virtio-pci behind the IOMMU from M9's kernel part; the drivers' move
   is a device record and a DMA profile, not driver code. The manifest
   check refuses an unconfined DMA device in the display domain of a
   release manifest, while the Phase 1 manifest check allows one in a
   development build; on Fiasco a compromise of the display domain's
   Erlang reaches the GPU's DMA, a recorded residual.
4. **A kiosk on QEMU `virt`**, in 1b-C, in two steps. Part 4a, after
   part 3, draws the kiosk, `examples/dashboard`, with `erx-lvgl` on the
   host and checks the frame against its reference picture, with a fixed
   board and no package; it needs no network. Part 4b, after part 4a,
   parts 2 and 3, 1b-B's sub-space ports and pipes, the first slice of
   1b-D and track A's second part, is the first boot of that interface
   on QEMU `virt`, as the kiosk's app, a package added to the image:
   `erx_ui_lvgl` in the application's session, and `erx-lvgl`, LVGL as a
   native program of that session drawing into the window's buffer,
   which holds its pipes and its buffer's pages and nothing else
   ([design-display.md](design-display.md#kiosks-and-glasses),
   [design-packaging.md](design-packaging.md#the-sdk)). The kiosk's
   quotes are fetched over HTTPS
   ([its README](../examples/dashboard/README.md)); with no network
   device each quote shows `no data`, and its live quotes wait for 1b-G's
   network.
5. **Kiosks on boards**, after part 4 and M12's boards. The firmware
   framebuffer driver of the Raspberry Pi comes earlier, with 1b-I's
   stage (d) on Fiasco; this part adds a panel on a serial bus, on
   the copy path and on the direct path; touch, encoder and keypad
   drivers, and the input file that an input device's domain serves the
   display where the device is in another domain, such as the devices
   domain; the idle policy, with the panel off when idle; the reserved
   chord, which reaches no window; Gate GD on the panel, once part 7's
   Erlang renderer runs
   ([design-display.md](design-display.md#kiosks-and-glasses)).
6. **A desktop on QEMU `virt`**, as 1b-F, after part 3, which brings the
   display domain, its drivers and the window tree: the overlapping policy
   with its menu, draw connections in the session, a program's
   `/dev/draw`, `/clipboard`, the terminal `erx_term` as the master of a
   tty of the session's terminal relay, and the desktop's session, a start
   row naming `root` and the display
   ([design-display.md](design-display.md#windows-and-the-window-system),
   [design-display.md](design-display.md#the-draw-connection),
   [design-display.md](design-display.md#the-terminal),
   [design-display.md](design-display.md#a-displays-session)).
7. **Widgets and presentations on the desktop**, in 1b-F, after part 6:
   the Erlang renderer in the application's session, the LVGL renderer in
   a desktop's window, the kiosk's program unchanged, and presentations
   at a terminal; the Erlang renderer's QEMU frame time is Gate GD's
   preview, deciding nothing
   ([design-display.md](design-display.md#presentations)).
8. **Desktop programs**, in 1b-F, after part 7, which brings the Erlang
   renderer and the parity test, and part 6, which brings the terminal
   from which the programs' commands run: the application `erx_desk` with
   `stats`, `clock`, `month` and `files`, each an Erlang command that
   opens one window; the widget format's additions through the validator,
   every reader and every renderer; the theme file and its generator; and
   the glyph step, rasterising Inter 4.1 and erXos's icons through
   FreeType ([design-desktop-programs.md](design-desktop-programs.md)).
   `clock` is the first program a person sees and `month` the second; both
   ship on `fixed` glyphs before the theme, which then restyles them.
9. **The web on the network**, after part 2, M10's logins, M11's vault
   and 1b-G's network service with TLS. cowboy over TLS in the web domain;
   the web domain's logins through the login facet
   ([design-login.md](design-login.md)), its cookies and a session per login; the manifest
   check's refusal of plain HTTP in a release build
   ([design-web.md](design-web.md#the-network-front-end)).
10. **GPU acceleration**, OpenGL-class rendering for the desktop and for
    kiosk apps, after part 8 and after a research record and a design of
    its own: a render service in the domain that holds the GPU fills
    clients' buffers in their own pixel areas, and the clients present
    them as any buffer
    ([design-display.md](design-display.md#graphics-hardware)). The
    Raspberry Pi's V3D and QEMU's virtio-gpu 3D modes are the candidate
    devices. Its packages, exit criteria and gates are written with its
    design; no other part waits for it.

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
own facets (design-web's W1 over the host link); `make web`
twice with the network disabled gives byte-identical files; each
chokepoint check catches its seeded violation; the end-to-end tests run
`tools/erx web` against a QEMU guest under HVF.

**Exit criteria, widgets on the web.** A user interface attached,
detached, changed and re-attached shows the newest tree,
`apply(delta(A, B), A) == B` over random trees, and a tree whose
difference exceeds one update arrives over several and applies at
`commit`; `erx_ui:open/1` in a session with no display answers `{error,
no_display}` at once and opens on the display its options name; the web
domain's release holds no widget server, which an xref check with a
seeded violation confirms; a restarted web domain ends no user interface
of `root`'s session, and closing every browser ends none; scrolling,
focus and selection in the browser send nothing to the machine; a
`secret` input's text appears in no counter, log, trace or crash report;
the `ui.txt` readers' fuzz targets run their budgets clean.

**Exit criteria, the window stack on QEMU `virt`.** A connection with a
pixel area charges the display's child budget by exactly the area and
gives it back at the connection's end, the display's capability to it
carries no `WRITE`, and a client killed during a copy leaves the copy
whole; `erx_winctl`'s fuzz target runs its budget clean, and a `present`
whose buffer passes the area's end, starts off a page boundary or has a
malformed rectangle is refused and the driver never called, while one
whose rectangles leave the window or whose buffer differs from the
window's size is shown clipped to the window; against a driver model
that never answers, a client's `wctl` moves and windows made and
removed by the thousand leave `erx_screen`'s heap within its bound
(G3); a reused pixel range reads zero; `erx_screen_core`
explored exhaustively, and G2's hosted runs under TSan and ASan; a
window has one present in flight, and a client that floods presents
delays another window's present by no more than two frames (G3); the
virtio-gpu response and virtio-input event parsers' fuzz targets run
their budgets clean; a driver restart is followed by one repaint of the
whole screen from the windows' buffers, with no client asked; the
display makes no device request between two presents or changes of the
layout (design-display's G6); the copy under UBSan
at its bounds; the display's session starts at boot with no login, its
window covers the screen, and a screenshot through QEMU's monitor equals
the reference image under HVF; ending the session's domain brings a new
session and its window, and ending it more often than its start row's
intensity allows leaves the background and the row `down`; a second window
of the session and a window of another domain stay hidden and take no
input (G1); each seeded violation of property 18 fails the manifest
check; a release manifest that gives the display domain an unconfined
DMA device fails the manifest check (design-display's confinement test),
while a development build's manifest with Fiasco's virtio-mmio
devices passes the Phase 1 manifest check; each chokepoint check catches
its seeded violation. With a kiosk running, the display domain killed
and restarted gives the kiosk's session its screen back, where a
re-mint that drops the session mark fails; `service enable` of a row
whose display another enabled row holds, or whose template is not
granted the display, is refused, and a kiosk's session starts at boot
with its display through the start table.

**Exit criteria, a kiosk on QEMU `virt`.** The parity test runs one
corpus of trees and input sequences through LVGL and the browser
renderer and finds the same events, values and nodes; the fuzz targets
of the C reader, of the Erlang reader of the program's records, the
`damage` report among them, and of the startup message's decoder with
the `mem` descriptor run their budgets clean; a `damage` rectangle
outside the size it was drawn at, or a second report before
`presented`, stops the program and ends the user interface with
`renderer_down`, while a report drawn before a resize is shown clipped;
a refresh of several areas completes with one report; the program's
sub-space maps its buffer's pages and no other page of the pixel area,
and the program draws nothing between a `damage` report and its
`presented`; killing the application brings its window back from its
supervisor, and ending its session's domain brings a new session while
a second app holding the display's grant stays
hidden; the kiosk's image boots into its app with no login, and two
images whose `app` and `start` rows name different apps share every
other row of the manifest and the display domain's release; between
two changes of its tree the kiosk makes no device request and its
program does not wake (design-display's G6); a screenshot through QEMU's monitor equals the reference
image under HVF; each chokepoint check catches its seeded violation.

**Exit criteria, kiosks on boards.** The fuzz targets of the touch,
keypad and encoder parsers and of the reader of an input file's records
run their budgets clean; a panel driver passes against a model of its
command set on the host, on the copy path and on the direct path, which
send the same bytes; the reserved chord reaches no window; the panel
turns `dim` and `off` after the idle times and on at the next input;
design-display's G6 at the driver, no device request between two
changes of the kiosk's tree; a Raspberry Pi 4 kiosk boots into its
application.

**Exit criteria, the desktop.** `erx_draw_core` explored exhaustively,
where a seeded skip of the quota check fails; the draw decoder's fuzz
target and its differential test against the C decoder; `erx_memdraw`
agrees pixel for pixel with `erx_draw_ref` over random compositing
operations and with the 9front build over every operation, shapes
included, also
under ASan and UBSan with rectangles far outside every image; the `Y`
decoder's fuzz target; a seventeenth dirty rectangle yields one
bounding box and a `mouse` queue past 4 KiB drops its oldest record; G1's
tests across grants, sessions and a narrowed program; G9's source check
that the display domain's release holds no draw decoder, widget code or
font reader, with its seeded violation; a draw connection's end
frees its images, measured by the session's budget; the `wctl` grammar's
fuzz target; the policies' property tests; `erx_vt` explored, fuzzed and
compared with a host terminal emulator's screen over a corpus that
includes `vttest`'s core; V1's byte test of design-live with `erx_term`
in place of the serial line; screenshots through QEMU's monitor equal the reference
images under HVF; a fault injected for each row of
design-display's failure table has that row's effect and recovery and
loses only what the failing party owned (requirement 10 and the
failures test of
[design-display.md](design-display.md#verification-and-testing)); a
display's session gets
its terminal's window at boot, and a new one when its last window
closes, where a seeded domain service that skips the introduction fails;
with the display running, the console's lines are the UART and the host
link alone and the display domain holds no facet of the console service;
`erx:attach` of `root`'s UART session from a terminal on the
display gives that session without the system-shell facet;
each chokepoint check catches its seeded
violation.

**Exit criteria, widgets and presentations on the desktop.** The parity
test runs one corpus of trees and input sequences through the Erlang and
the browser renderers and finds the same events, values and nodes, and
the LVGL renderer in a desktop's window passes the kiosk's;
`parse(Type, text(Type, Value)) == Value` for every type of the schema;
links appear only at a tty that declares `links`; the link parser's fuzz
target runs its budget clean; the input context highlights exactly the
types the catalog declares for the command typed; G4's `no_facet` test,
where a seeded facet call in the emulator is caught by the source check;
G7's status tests through a widget tree; `erx_ui_schema`'s fuzz target
over arbitrary terms runs its budget clean.

**Exit criteria, desktop programs.** Each core's host tests of
[design-desktop-programs.md](design-desktop-programs.md#verification-and-testing)
pass and each fails on its seeded fault: stats' derivation keeps every
status (D2), keeps no partial sample as exact, turns a counter that
goes down or a zero denominator into a gap, shows the machine's load
and only the session's own domains to a scoped facet, keeps one sample
in flight and drops a stale answer; clock never shows an unset clock's reading as a date
(D3), ticks at each minute's start and shows a wall step by the first
tick after it; month equals `calendar` for every month from 1600 to
2400; files acts by index, never by shown text (D4), drops an event
from a replaced listing, pages past 256 items asking information for
one page, refuses a folder past its listing worker's heap cap (D8) and
reads at most 16 KiB for a preview; no worker outlives its window
(D9); every tree from random listings, names and records passes
`erx_ui_schema` (D5); an idle files window and
a month without a today issue no tree in a simulated day (D6). Each
program's frame through `erx_ui_host` equals its reference; the attributed-text corpus as file names and a domain name
draws its tokens; the parity test passes through the Erlang, LVGL and
browser renderers with the new kinds and properties; the validator
refuses each malformed addition and the readers' fuzz targets run their
budgets clean; `erx_mask`'s corners match analytic areas; the glyph
step's output is byte-identical over two runs; a seeded low-contrast
colour and a `contrast` row naming an undeclared colour fail the
theme's generator (D7);
the source check that `erx_desk` calls only the public surface and
`erx:inspect/2` catches its seeded call (D1). In the `display_domain`
suite, a screenshot of `files` and `month 11 2026` equals the reference
image under HVF, and stats' window presents at least twice in three
seconds while clock's presents at most once.

**Exit criteria, the web on the network.** Two principals logged in
through cowboy each see their own `/proc` snapshots and `ended scope` for
the other's domains (W1); one scripted client through the host tool and
through cowboy receives byte-identical messages (W5); a logout ends only
its own session; the seventeenth login is refused; a release manifest that
allows plain HTTP fails the manifest check.

**Gate GW, with part 1.** Measures a record view's round trip over the
host tool's front end, for the machine's record and a 1,000-child listing,
under HVF and over a host link paced to a 115,200-baud UART's rate
(`tools/erx bench web`); the pacer stands in for the UART, and a board's
UART measures it again at M12. Decides whether whole records stay on the
wire or the protocol gains a record difference: whole records stay, since
an update of the listing crosses the paced link in about 1.1 s, so a view
of a changing listing still refreshes about once a second
([design-web.md](design-web.md#risks-and-open-questions)).

**Gate GD, on part 5's panel, once part 7's Erlang renderer runs.**
Measures the Erlang renderer's difference, layout and drawing time per frame on a 240
by 240 panel
against LVGL's, on the same panel, with the parity test passing through
both. Decides whether LVGL leaves the panels; while it does not, LVGL
stays behind the renderer behaviour and the gate is measured again as the
Erlang renderer improves
([design-display.md](design-display.md#risks-and-decisions)).

## Track A: Apps

**Goal.** Code that runs for no person, a kiosk's screen first, runs as
an app: a principal with a session template, whose release is its code
and whose facet rows are its authority, started and kept by the start
table, the one place that says what starts without a person
([design-apps.md](design-apps.md)); an app built outside the tree is a
package, added to an image or installed at run time
([design-packaging.md](design-packaging.md)).

**Demo.** A QEMU image boots into an app's session with no login, the
app holding exactly its template's grants; `service -e` prints the
configured domains and the start table; `service clock disable` and a
reboot leave the app stopped; a kiosk's app killed past its row's
intensity shows its row `down` at `/proc/apps`; `examples/dashboard`,
built with the SDK alone and added with `tools/erx pack --app`, is the
kiosk's screen; `cp dashboard.app /apps/` installs it on a running
machine, where `ls /apps/dashboard.app` browses it.

**Scope.** Three parts, all in Phase 1b, on Fiasco. The first is
the start table, which track D's window stack needs; the second packages
apps built outside the tree and adds them to an image, which track D's
kiosk needs; the third installs, updates and removes packages at run
time.

**The first two apps, two milestones each.** The kiosk's are part 4a and
part 4b of 1b-C's track D. The second app is a demo that exercises
programs, windows and keyboard input; it is built out of tree and never
shipped, and nothing of it enters erXos. Its basic milestone is Doom on
QEMU `virt`, with keys from QEMU's virtio keyboard and a presentation on
each frame end. Its full milestone is Doom as an app: a package built
from `examples/doom`, a submodule of erXos's fork of the demo built only
on request, with keys still from the virtio keyboard, its WAD read from
a file through `lseek`, `pread` and `fstat` on the program protocol's
64-bit offsets, and its window's draw connection reached through the
program's own `/dev`
([design-files.md](design-files.md)). A USB keyboard
follows with [track U](#track-u-usb), not as part of the milestone.

**What comes first.** The highest priority is two basic apps, each a
package added to an image and booted on QEMU `virt`: the kiosk, booted
offline (`examples/dashboard`, each quote showing `no data`) and Doom with keys
from QEMU's virtio keyboard. That is track A's second part and what the
two apps stand on, then the kiosk's and Doom's full milestones. Work
runs at full parallelism: every worker these items cannot use takes the
next available item of the plan.

1. **The start table**, in 1b, after 1b-A, 1b-B's session domain and
   M6's data partition, whose `etc` tree holds `start.conf`: the
   manifest's `start` rows and property 17; `erx_starter` with one
   supervisor and keeper per enabled row; `start.conf`, read at boot and
   at each command, and its merge, which sets only rows the manifest
   declares and refuses a display the row's template is not granted or
   another enabled row holds; the start service's tree with `ctl`;
   `service`, whose `enable` and `disable` edit `/etc/start.conf`; and
   `/proc/apps` ([design-apps.md](design-apps.md#the-start-table)). An app
   is a principal of the manifest with its own template and release.
2. **Packages added to an image**, after part 1: the `apps`, `package` and
   `signer` rows and property 19, the package format and its admission,
   the app's session with `/app`, the `apps` tree mounted at `/apps`,
   `/proc/packages`, and the SDK with `erx-app pack` and `tools/erx pack
   --app` ([design-packaging.md](design-packaging.md),
   [design-packaging.md](design-packaging.md#the-sdk));
   `examples/dashboard` built through the SDK alone, and `examples/doom`
   as a submodule built only on request. The image's packages lie in the
   slot's system partition and are read through the `system` tree, so
   this part follows M6's `system` tree; the packer refuses a boot image
   that holds a package.
3. **Installing at run time**, after part 2, M6's data partition and
   1b-E's storage domain: the storage service's `packages` tree, the
   `apps` tree's installed packages, whose close installs or updates and
   whose `unlinkat` removes, publication that answers once a dropped app's
   sessions have ended, and bounded recovery after a crash
   ([design-packaging.md](design-packaging.md)). One check of
   design-packaging.md lands later (TODO.md, security residuals): `purge`
   with the storage service's `remove_app` and directories named by
   signer, at M10.

**Exit criteria, the start table.** The merge's host tests and their
seeded faults (a row added for an undeclared principal, the display
rule dropped, the grant check dropped) and the row supervisor's (a
keeper that does not monitor its session) fail as designed; a manifest
with an enabled start row boots to that row's session with no login,
holding exactly its template's grants, and one with none to the
console's alone; a session killed is started again, and past the row's
intensity the row is `down` at `/proc/apps`;
`service enable` and `disable` edit `/etc/start.conf` and survive a
reboot, and an edit of the file changes nothing at a command for
another row, only at the row's own `service` command or the next
boot; a session whose template holds no `start` grant
cannot reach `/etc/start`, `/etc/start.conf` or `/apps`;
`start.conf`'s and `ctl`'s fuzz targets run their budgets clean; each seeded violation of property
17 fails the manifest check; each chokepoint check catches its seeded
violation. The kiosk tests, the display domain restarted giving the
kiosk's session its screen back, and the refusal of an enable on a
display another row holds or the template is not granted wait for
Track D's part 3, which builds the display domain. The rescue
configuration starting no row and the reset count cleared by the first
kept session wait for M12, which builds the reset count and the rescue
configuration. A user's session holds only its home and cannot rewrite
`start.conf`; root's session, which holds `data`, the whole volume, in a
development build, can, as FreeBSD's root can (property 19).

**Exit criteria, packages added to an image.** `examples/dashboard`
builds, packs and passes its host test with nothing but the exported
SDK on its paths, and the boundary check refuses its seeded call of a
private function; a kiosk image made with `tools/erx pack --app
examples/dashboard --enable dashboard` boots to the dashboard on the
display, with the board's manifest source unchanged, its session holding
exactly the services its declaration names and the `packages` grant;
two apps see none of each other's domains at `/proc`; a packaged test program with a window
draws through `/dev/draw` and answers a key; each seeded fault of
design-packaging.md's host tests and each seeded violation of property
19 fails as designed; the header's and the declaration's fuzz targets
run their budgets clean; no build list names `examples/`, and `make
check` needs no `examples/doom`.

**Exit criteria, installing at run time.** In a development build,
`cp` of a package into `/apps` shows it `admitted` at
`/proc/packages`, with its signer `development`, and its image readable
through `mount /apps/NAME.app DIR`; `service NAME enable` starts
nothing and `service NAME start` then starts it, and a reboot keeps it;
a newer build copied over it stops it and starts nothing, whatever
`start.conf` says, and `service NAME restart` runs the new build with the
app's files kept, and one cut short fails its `cp` and leaves the old one running;
`rm` of it leaves no package or row, no session of it once the
publication has answered, and the app's directory; a copy cut short
fails its `cp` and publishes no name; the planners' crash and failure tests
over reordered writes, the package lifetime's test with a crash among
concurrent copies and a queued close, and the recovery's fuzz target
pass, with their seeded faults; installing and removing more distinct
names than the `apps` row's `max` in one boot refuses the last with
`apps_full`. A flipped image byte giving `eio` and the row `down`, and
the refusal of an untrusted signer or a flipped header byte, are exit
criteria of M11; `purge`
removing an app's directory is one of M10.

## M6: Immutable code, lasting data

**Goal.** The system's files come from immutable images read through one
block-checking funnel, and one practical store keeps data across power
cuts, so the system is one a person can use.

**Demo.** A QEMU disk image holds a slot, its boot and its system
partition, and a data partition. Booted from it, the shell reads a file
of the system partition through the storage domain's `system` tree and
mounts the self-checking image it holds; a file written and synced under `/data` survives
the guest's power cut and the next boot.

**Scope.**

* **A block device.** The virtio-mmio block driver, an Erlang process
  under a supervisor in the system domain, over the device NIF
  ([design-runtime.md](design-runtime.md#the-device-nif),
  [design-system.md](design-system.md#drivers)), with ordinary interrupts
  and unconfined DMA, Fiasco's driver profile, which M9's kernel part
  replaces with virtio-pci behind the IOMMU and M11 refuses unless
  configured; partition windows in the block service, with the partition
  table and its fuzz target
  ([design-storage.md](design-storage.md#data-model)).
* **Immutable code and files.** `erx_verity:read/3` as the one funnel,
  which checks each block against its image's hash tree, through which
  the EROFS reader reads every block; each slot's system partition in
  EROFS, which the storage domain serves as the `system` tree; the
  file-backed EROFS mount; CRC-32C among the per-byte primitives
  ([design-runtime.md](design-runtime.md#per-byte-primitives)); fsimg as
  the packer's host tool, which writes and verifies each image; and the
  packer's disk image for QEMU, laid out by the ABI file's medium layout
  ([design-storage.md](design-storage.md)).
* **One practical data store.** littlefs as the stopgap read-write file
  system behind `erx_fs`'s callback module, with a fuzz target for its
  images, on the data partition
  ([design-storage.md](design-storage.md#read-write-storage)); its
  sub-space port form lands once track S's port driver (1b-B) exists, in
  the storage domain, behind the same callback module; 0.2 ships the NIF
  form in the storage domain, under its release contract
  ([design-stopgap.md](design-stopgap.md#release-contract)).
* **Booting from the disk image.** The QEMU harness's normal boot, without
  trials: it plays the firmware, reads the record from the disk image with
  its slot parser, which has its fuzz target, boots the slot the record
  names and writes the boot value into `/chosen`, so the device service
  grants the storage domain its read-only window on the booted slot's
  system partition
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

## 0.1: The preview

**Goal.** 0.1, erXos's first public preview, is published: a development
build that a person can download or build and use on a Raspberry Pi 4 or
on QEMU `virt`, with the kiosk and its live quotes on the screen, `rc`
over SSH, files under `/data` that survive a power cut once closed, and
Doom in both images, played on QEMU and running its demo loop on the Pi.
Its banner says `development build: trusted code only`, and it runs
trusted code only. The website offers its browser demo and its Raspberry
Pi 4 card, built from the commit tagged `v0.1`, with the release notes beside
them ([site/README.md](../site/README.md)). The work is ordered towards
0.2, the first full release, a release build on Fiasco with logins,
untrusted apps and the closure ([0.2](#02-the-first-release-on-fiasco)).

**Demo.** A Raspberry Pi 4 boots from an SD card written from 0.1's
published image, shows the development banner and the shell on its
serial console, and shows the kiosk, `examples/dashboard` with its
clock and its quotes panel, on its HDMI screen through the firmware's
framebuffer. The panel shows live quotes fetched over HTTPS from boot,
since the clock starts at the build's date and the published image is
younger than the sources' certificates
([design-time.md](design-time.md#the-approximate-start)). From another
machine, `ssh -p 2222 root@` the board, with the public key its user put
in `authorized_keys` on the card's record partition, reaches `rc`.
`ntpd` has set the exact time at boot; root can also set it by hand. In
the same session `ps` and `top` show the session's `rc` and the programs
it runs, `ls /proc/domains` lists every domain of the machine, the
kiosk's among them, and `erl`'s `erx:i()` prints the machine, its CPUs
and processes. A file under `/data` survives a power cut once it is
closed; 0.1 has no `sync`. A fault of the system domain resets the
board, which boots back to the kiosk; so does a hang of the root,
through the board's hardware watchdog. On the Pi, `halt` leaves the
board halted until its power is cycled. The QEMU image of the same build
boots on QEMU `virt` with the same kiosk on its display and SSH through
a host port forward. On QEMU, Doom, `/bin/doom` of both images, started
from `rc`, plays with keys from QEMU's virtio keyboard; on the Pi it
runs its demo loop with no keyboard, very slowly (`TODO.md`). The
website's browser demo runs 0.1's image.

**Scope.** Each item names the design that owns it.

* **Two platforms**: the Raspberry Pi 4 and QEMU `virt`. On the Pi,
  1b-I's parts (a) to (d)
  ([1b-I](#1b-i-the-raspberry-pi-4-on-fiasco),
  [design-platforms.md](design-platforms.md#raspberry-pi-4-model-b),
  [design-fiasco.md](design-fiasco.md#the-raspberry-pi-4)); its
  parts (e), the header with the clock module, and (f), WiFi, are not
  0.1's.
* **The kiosk with live quotes**: track D's parts 3, 4a and 4b in 1b-C
  on track A's parts 1 and 2, and the kiosk's live quotes over HTTPS of
  track D's part 4 ([its README](../examples/dashboard/README.md)), on 1b-G's network on
  QEMU and on the Pi's Ethernet, 1b-I's part (c). It draws on QEMU
  `virt`'s virtio-gpu and on the Pi's firmware framebuffer, 1b-I's part
  (d) ([design-display.md](design-display.md#kiosks-and-glasses)). The
  published images carry `examples/dashboard`, declared `needs display
  net`, packed with `tools/erx pack --app` and enabled on the display
  ([design-packaging.md](design-packaging.md#adding-an-app-to-an-image)).
  The clock starts at the build's date, so the quotes are live from
  boot, and root's `date` sets it exactly; a build without a date
  leaves it unset, and then every quote reads `no data: clock not set`
  ([its README](../examples/dashboard/README.md#the-clock)).
* **The clock.** With no time source the clock service starts the wall
  clock at the build's date, approximate, which the live quotes' TLS
  checks accept
  ([design-time.md](design-time.md#the-approximate-start)). `ntpd` sets
  it from an NTP server at boot on the Pi 4's image; root sets it by hand
  with FreeBSD's `date` and a time argument
  ([design-time.md](design-time.md#setting-the-clock-by-hand)), or with
  `ntpctl step`, from a server it names or from ntpd's last sample
  ([design-time.md](design-time.md#setting-the-clock-from-a-server-once)).
  0.1 has no real-time clock module; the header that carries one is
  1b-I's part (e).
* **Doom on QEMU `virt`**, with keys from QEMU's virtio keyboard, and
  **on the Pi as its demo loop** with no keyboard, since the Pi has no
  keyboard before [track U](#track-u-usb). It is `/bin/doom`, a program
  of the domain release in both published images, under the dependency
  status `example` ([design.md](design.md#dependencies)), started from
  `rc` with a window of its own, whose `/dev` holds `draw` and `kbd`. Its
  source is offered with the images: erXos's fork at the commit the
  tree's gitlink records. `tools/erx fetch --example doom` fetches the
  fork and Freedoom's WAD, and the published build, `tools/erx pack
  --published` (`make pack`), links both into `/bin/doom` and refuses
  without them. Doom
  as a package built from `examples/doom`, on 1b-D's first slice
  (`erx_exec` and the program protocol's 64-bit file calls), stays
  track A's full milestone
  ([design-packaging.md](design-packaging.md#examples)).
* **Building from source.** erXos's repository and its Doom fork's
  repository are public, so a user clones erXos, builds both images
  with the repository's own steps, and fetches the Doom fork into that
  clone.
* **SSH to `rc`**: SSH's stage 1 ([design-ssh.md](design-ssh.md#stages)),
  `erx_ssh_dev` running OTP's ssh daemon in root's own session with
  root's own `net` grant, giving `rc` on a tty of that session, on QEMU
  in 1b-G and over the Pi's Ethernet in 1b-I's part (c). Its sessions are
  interactive ttys only; an `exec` request, such as `ssh host cmd`, is
  refused. It listens on
  port 2222, since a privileged port is only a configured domain's;
  port 22 comes with the SSH domain. The SSH domain,
  the login facet and exec jobs, stages 2 and 3, are 0.2's. The host key
  is made at the first boot in root's `/data/ssh` and kept across reboots
  ([design-ssh.md](design-ssh.md#host-keys)). The published images
  carry no login key (`Checks::LOGIN_KEY_BUILDERS`); root's login key
  is the user's, written to `authorized_keys` on the card's record
  partition, which the first boot imports into root's home copy,
  `/root/.ssh/authorized_keys`, the only file read from then on
  ([design-ssh.md](design-ssh.md#roots-login-keys-on-the-medium)); root's
  session can write the home copy, so a root login can add a key that
  lasts, and whoever can write the card can make themselves root: known
  limitations.
* **`ps` and `top` over SSH**: the command shell's `ps` and `top` in
  root's SSH session list the session's own process table, its `rc` and
  the programs it runs, as a UNIX user's `ps` lists their own processes
  ([design-shell.md](design-shell.md#text-commands)). The machine-wide
  view is `/proc`, whose `domains` directory lists every domain, and
  `erl`'s `erx:i()`, through the session's inspect facet, whose scope a
  development build makes `all` for root's session
  ([design-live.md](design-live.md#inspection),
  [The /proc tree](design-live.md#the-proc-tree)).
* **Persistence and recovery.** `/data` on littlefs on the card, 1b-I's
  part (b) ([design-stopgap.md](design-stopgap.md#littlefs-in-the-storage-domain));
  a file there survives a power cut once it is closed, and 0.1 has no
  `sync`. A root fault and a missed pet reset the machine, as
  [design-fiasco.md](design-fiasco.md#the-end-path) has it: 0.1
  takes the end path's reset, in which every end names its cause. The
  root's watchdog thread arms the Pi 4's power-management watchdog on
  every boot and reloads it at each step, so a hang of Fiasco or of the
  root resets the board within 4 s
  ([design-fiasco.md](design-fiasco.md#the-watchdog), FD29); its
  registers come from a clean-room facts record of the watchdog, as the
  RNG200's do. On the Pi a
  requested power-off, `halt`, leaves the board halted until its power
  is cycled. Updates are by reflashing the card, which takes `/data`
  with it; no update service and no trial boot.
* **The preview's kernel.** 0.1's images are development builds and
  carry the development kernel, with the kernel debugger and the
  kernel's own console input, by decision
  ([design-fiasco.md](design-fiasco.md#boot-handoff)): a panic enters
  the debugger on the console, and on the Pi 4 the hardware watchdog,
  once the root has armed it, resets the board within its timeout; QEMU `virt` has no hardware
  watchdog, so there a kernel panic stops in the debugger until the
  run's deadline or the user ends it. The debugger's `jdb_object.cpp`
  (GPL-2.0-only) goes out with its source offered, under CLAUDE.md's
  exception for the website's images. Leaving the debugger out is the
  release kernel's, in 0.2.
* **A distributable closure.** The shipped images' link closure is
  distributable under the license allowlist of
  [design.md](design.md#licenses-and-notices), which admits Fiasco's
  one GPL-headed file the images carry, `jdb_object.cpp`, only through
  its row of the closed table, in development builds alone. The kernel
  takes the clean-room header of 0.2's release Fiasco build
  ([design-fiasco.md](design-fiasco.md#the-releases-fiasco-build)):
  `kobject_rpc.h`, which the kernel cannot build without, rewritten
  clean-room under MIT. The dependency table names no other component
  under a license that is not permissive in an image beyond the
  accepted ones: the Pi 4's device tree under GPL-2.0, shipped with its
  source, and the Raspberry Pi firmware under Broadcom's license
  ([design.md](design.md#dependencies)). The
  packer refuses a package that is not permissive in every image but a
  local one ([design-packaging.md](design-packaging.md#adding-an-app-to-an-image));
  Doom, an example, enters as `/bin/doom` under GPL-2.0-or-later, the
  one input the image build accepts under the status `example`
  ([design.md](design.md#dependencies)).
* **Images.** One SD card image for the Pi 4 and one QEMU medium, from
  one build of one commit, each with its build record and SHA-256
  ([design-build.md](design-build.md)). The website offers the card
  beside its record, an image for QEMU `virt`'s `-kernel` and the
  browser demo ([site/README.md](../site/README.md)); the QEMU medium is
  built from source.
* **Documentation.** The getting-started steps for the Pi and for QEMU
  are in the README, grown from its "Boot erXos" and "Raspberry Pi 4 SD
  card" and from
  [the Raspberry Pi 4 guide](guide/raspberry-pi-4.md).
  The release notes are a page the website publishes beside the
  downloads, its source under `site/`. They carry 0.1's known
  limitations: what it leaves to 0.2 and later (below); the Pi's clock, at
  the build's date at each boot until `ntpd` or root sets it, so a certificate that
  expired since the build is accepted until then; and the security residuals a user of 0.1 is exposed
  to, each pointing to its design section or its
  `TODO.md` item rather than copying it: a development build, which runs
  only trusted code because it carries development-only grants and its
  isolation is hardened and reviewed only for 0.2; SSH's network-facing code, OTP's transport and authentication included, running in root's own session with root's authority, so a flaw in it reached before login is root's session ([design-ssh.md](design-ssh.md#stages), stage 1); root's session holding a read-only grant of the card's login keys (`login_keys`) for its first-boot import, so the keys are readable in a session beside the system domain, until the SSH domain of 0.2 removes the grant ([design-ssh.md](design-ssh.md#invariants), H8); the DMA handover
  evidence not recorded for the boards; and a host key made on a weak
  seed ([design-ssh.md](design-ssh.md#host-keys)) when a boot's seed is
  the counter alone
  ([TODO.md](../TODO.md)).

**Exit criteria.** 0.1 is published without these of its criteria,
which carry over: the soak of
[design-platforms.md](design-platforms.md#the-soak) and
`make check-reproducible` on the published media, both 0.2's exit
criteria; the license allowlist check over each published image's
whole closure and the fuzz budgets of the set-time command's and the
login-key reader's targets, which 0.2's criteria cover; the getting-started
steps run by hand on a clean clone, 0.2's; and the hardware watchdog's
checks by hand on the board and Doom on QEMU with the virtio keyboard
by hand, each a `TODO.md` item.

**Left to 0.2 and later.** The release build: no development banner, a
login on the console, untrusted apps, the vault and SSH's stage 4; the
backend on Fiasco's own mechanisms and the rest of the release's
Fiasco build (the writable-or-executable patch, the eager FP switch,
FD32's hardening, the system-call fuzz campaign and the upstream
watch); M9's kernel part's devices, the rest of track P, M10's users,
M12's updates and trial boots, track D's parts 5 and 9, and M11's
closure on Fiasco, all as 0.2 takes them; SSH's `exec`; track A's
part 3, installing an app at run time. Also after 0.1: playing Doom
on the Pi, which needs [track U](#track-u-usb)'s USB keyboard; 1b-I's parts (e) and (f); the
desktop of 1b-F; toybox's applets, the rest of 1b-B; 1b-H; and track B.

**Dependencies.** Phase 1; 1b-A; 1b-B's session domain, sub-space ports
and pipes; 1b-E's storage, network and display domains' devices; track
A's parts 1 and 2; 1b-C's parts 3, 4a and 4b and the kiosk's live quotes of
track D's part 4; 1b-D's first slice for Doom; 1b-G with SSH's stage 1;
and 1b-I's parts (a) to (d), with SSH's stage 1 over Ethernet in part (c).

## 0.2: The first release, on Fiasco

**Goal.** erXos's first full release, with every user feature, on Fiasco: the
backend on Fiasco's own mechanisms, the security closure in its Fiasco
form, and what Fiasco lacks against erXos's kernel published as
downsides ([design-fiasco.md](design-fiasco.md)).

**Demo.** A release build boots without the development banner on QEMU
`virt` and on a Raspberry Pi 4 and asks for a login on its console. An
installed app whose code is untrusted runs in its session; it reaches no
other domain's memory or objects, stops at its memory wall with
`ENOMEM` while a neighbour still allocates, and spins every thread it
may create, in its own band, without delaying the display or a driver,
whose bands are higher (FD15); an app that floods a service or the
root with requests instead still delays them (FD17, FD31). A hostile test
domain invoking every slot of its object space leaves the root and a
neighbour answering. The release notes carry the downsides table.

**Scope.** Two parts.

* **The Fiasco target**, as [design-fiasco.md](design-fiasco.md)
  describes it: handles as Fiasco slots, with the root's placement
  records; a Fiasco factory per domain budget, so budgets are walls for
  kernel memory as for user pages; doorbells and device lines placed
  directly in their holders, so a trigger and an acknowledgement reach
  Fiasco without the root; priority bands, CPU sets and thread limits
  from the manifest; the whole-space pause by the root; DMA spaces
  behind an IOMMU and MSIs where the platform has them, though no
  device of 0.2's platforms is behind an IOMMU, so a DMA-capable
  device's domain is in the trusted base (FD12); the release's
  Fiasco build (the debugger off and its configuration check, the
  MIT clean-room `kobject_rpc.h` in the GPL original's place, the release kernel's
  build without `jdb_object.cpp`, the writable-or-executable patch, and the check that the image's link
  closure is all permissive, and the eager FP switch); the system-call
  fuzz campaign; and the upstream security watch. The build also
  hardens Fiasco's entry against branch-predictor injection only if the
  null-request bench on the Raspberry Pi 4 shows the patch costs nothing
  measurable; otherwise FD32 stays a published downside
  ([design-fiasco.md](design-fiasco.md#the-releases-fiasco-build)).
* **The user features.** Phase 1 and 1b and track A, and the
  user-facing milestones that otherwise wait for erXos's kernel, each in its Fiasco
  form with its criteria that need erXos's kernel left to that
  milestone after M7: M9's kernel part's devices (virtio-pci with MSIs,
  the PCIe domain alone reaching configuration space, DMA confined by
  Fiasco's DMA spaces where an IOMMU stands behind the device, which on
  0.2's platforms is nowhere); the rest of track P, on Fiasco's vCPU row;
  M10's users, their CPU held by bands rather than shares; M12's
  boards, storage and updates, with littlefs on the boards' data
  partitions, and a card image that holds only what is written: the
  populated partitions first, the image ending after boot A, and first
  boot setting up the rest, data taking the rest of the card (`TODO.md`);
  track D's parts 5 and 9; the system trust store from Mozilla NSS's
  root list, as FreeBSD's `secure/caroot` and `certctl(8)` (`TODO.md`);
  and M11's
  closure in its Fiasco form
  ([design-fiasco.md](design-fiasco.md#the-security-closure)). Track Q
  follows 0.2, since its copy-on-write children, store tracking and
  space copy (`erx_mem_child`, `erx_mem_dirty`, `erx_space_copy`) are
  refused on Fiasco (FD9).
* **Two stopgaps, under release contracts.** littlefs, as a NIF in the
  storage domain, with every grant of the data partition's services
  rooted at its client's home, its app's directory or its service's
  ([design-stopgap.md](design-stopgap.md#release-contract)),
  and LVGL, as a program of its application's session
  ([design-display.md](design-display.md#lvgls-release-contract)). 0.2
  ships no other stopgap. 0.2 ships littlefs whatever G13 decides: M13's
  installation of erXos's F2FS on the boards follows 0.2. Gate GD decides
  whether LVGL leaves the panels; a release after a GD that retires it
  ships no LVGL.

**Exit criteria.**

* Every test of Phase 1, 1b and track A, and of each milestone 0.2 takes,
  passes on a release build as on a development build: at the milestone
  gate the QEMU suites run on the release configuration beside the
  development one, and at the landing gate the release configuration
  boots once, a smoke test.
* littlefs and LVGL meet their release contracts: each of their tests
  passes and catches its seeded failure, and their published downsides
  are in the release notes beside Fiasco's.
* Each test of [design-fiasco.md](design-fiasco.md#verification) passes
  and catches its seeded failure.
* The system-call fuzz campaign runs its full budget with no open
  finding.
* The hostile suites' Fiasco set runs, and the cases Fiasco cannot
  carry report `unsupported`, never a pass.
* Every function-API and conformance case whose answer differs between
  the two kernels is a row of
  [The call table](design-fiasco.md#the-call-table).
* Every item of [M11](#m11-security-closure) that does not name erXos's
  kernel holds, the external review included.
* The release image's link closure is all permissive, with Fiasco's
  notices in `NOTICES`, and the license allowlist check of
  [design.md](design.md#licenses-and-notices) passes over each published
  image's whole closure and fails on its seed, a file recorded under
  GPL-2.0 added to the QEMU medium; the upstream watch is current.
* `make check-fuzz` runs every target's budget clean, the set-time
  command's and the login-key reader's among them.
* `make check-reproducible` passes on the published QEMU medium and
  Pi card, and their build records name 0.2's commit with no changes in
  the tree, which the website's build checks.
* The soak of [design-platforms.md](design-platforms.md#the-soak)
  passes on the 4 GB Raspberry Pi 4 from the published card and under
  the QEMU harness, as its design states it.
* By hand, the getting-started steps for QEMU and for the Pi, run as
  written on a clean clone and with the published images, reach the
  console, the kiosk and SSH.
* The measurements of
  [design-fiasco.md](design-fiasco.md#measurements) are recorded,
  the doorbell from ring to wake before and after among them.
* The downsides table is in the release notes and the user
  documentation.

Release images are built and their hashes published as M11 says, with
LLVM 23.1.3 pinned for Fiasco and for everything else.

**After 0.2.** [Track F](#track-f-fiasco-improved-to-the-decision)
improves Fiasco up to gate GF, which decides whether erXos builds its
own kernel. If it does, M7 replaces Fiasco at parity over 0.2's system,
and M2, the kernel parts of M5 and M9, M8, the criteria 0.2 left to
erXos's kernel and M11 on erXos's kernel close the downsides track F
leaves. While a release runs on Fiasco, the upstream watch continues.

## Track F: Fiasco, improved to the decision

**Goal.** Close or narrow, on Fiasco, the rows of
[the downsides table](design-fiasco.md#downsides-against-erxoss-kernel)
whose fix fits Fiasco's own approach, up to a stated point, and then
decide at gate GF whether erXos builds its own kernel. A fix fits
Fiasco's approach when it is a field and a check at Fiasco's own
lookup, a scheduler variant beside the ones Fiasco's configuration
already selects, a contained patch to its entry path, or a change to
the root service's tables and plans, including a pager in user mode,
which is how L4 systems are built on Fiasco. A fix goes against it when
it puts memory objects with no pager into Fiasco's kernel (in place of
its mapping database and `sigma0`), removes the root's tables, or
rebuilds Fiasco's code under erXos's construction rules (FD24); those
rows stay rows, and GF weighs them.

Each stage lands as ordinary commits to the fork, the backend or the
root, with its cases in [design-fiasco.md](design-fiasco.md#verification)
and a seeded fault for each check it adds, and edits its rows of the
downsides table to what it leaves. The stages start after 0.2; a fix a
0.2 item needs lands with that item. F1 to F4 are independent of one
another; F5 is Fiasco's scheduler stages, whose group quotas use the
scheduler core of erXos's C17 cores, and F6 uses their budget core. The
sizes are unverified estimates, none
prototyped ([research-fiasco-vs-kernel.md](research-fiasco-vs-kernel.md)).

* **F1, handles and records** (FD1, FD2, FD4, FD30 closed; FD6 and
  FD15's report narrowed; 700 to 1,600 lines). A generation in Fiasco's
  object-space slot and capability selector, checked in its one lookup
  (`Obj_space_phys::lookup_local`); a generation in the root's thread
  table and thread handles; `erx_cap_pass` planned whole before any item
  moves; the join race of FD30 fixed; Fiasco's own counts of kernel
  memory in use per quota and CPU time per thread read out.
  Exit criteria: a ring and an acknowledgement through a closed IRQ
  handle whose slot was reused answer `ERX_ESTALE`, and the case fails
  with the generation comparison removed; a thread queued on a deleted
  IRQ object wakes with `ERX_EDEAD`, or FD1 keeps that clause with the
  reason found in Fiasco's source; a thread handle kept past its space's
  deletion answers `ERX_ESTALE` once its index is reused; a pass refused
  at its last item leaves every earlier item where it was; the join race
  has a regression test that failed before the fix; the inspector shows
  each budget's kernel memory in use and each domain's CPU time from
  Fiasco's counts, where it showed `unsupported`.
* **F2, mappings and images** (FD10 closed, FD34 closed if Fiasco's
  overmap is atomic; FD8 and FD14 narrowed; 700 to 1,600 lines). The
  root's range table refuses a mapping that would make a page of an
  object without `ERX_MEM_JIT` writable in one place and executable in
  another; `sigma0`'s and the root's own image mapped by segment; an
  image map checks a file entry's hash before its first map and unmaps
  what a refused load mapped; a mapping replaced by one Fiasco map call
  over the old one; the task tables' limits, 128 threads among them,
  raised. Exit criteria: the writable-here, executable-there pair is
  refused, and the case fails with the check removed; a walk of the
  root's page tables finds no page writable and executable outside its
  pool window, the residue FD8 keeps; a file entry with one flipped byte
  is refused at its map, and a refused load leaves no segment mapped; a
  module's code swapped on four CPUs while a dirty scheduler reads it
  never finds the range unmapped, or FD34 records the probe that shows
  Fiasco's overmap is not atomic; one task runs more than 128 threads.
* **F3, threads, interrupts and upcalls** (FD19 closed; FD13 and FD23
  narrowed; 850 to 1,850 lines). `erx_thread_stop`, `_read` and
  `_write`, the start of a repaired thread and of further threads in a
  space, over Fiasco's `ex_regs`; Fiasco's IRQ acknowledgement checks a
  right; the vCPU upcalls widened so that an event ends a wait. Carves,
  routes and moves of IRQ objects between groups wait for a consumer.
  Exit criteria: the thread calls' conformance cases pass on both
  backends; an acknowledgement through a handle without `ack` is
  refused; a program's `sem_wait` interrupted by a signal returns
  `EINTR`, and a signal sent during a wait is handled before the wait
  returns.
* **F4, hardening** (FD32 closed if the patch costs nothing measurable,
  otherwise it stays a published downside; FD29's early-boot clause closed; FD33 narrowed; 150 to 450
  lines and an audit). Branch-predictor hardening at Fiasco's AArch64
  entry from user mode and at each switch between address spaces, as
  [design-arch-aarch64.md](design-arch-aarch64.md#speculation-mitigations)
  chooses from the CPU, shipped only if the null-request bench shows it
  costs nothing measurable, as 0.2's condition says; whether to ship it
  whatever its cost is deferred;
  Fiasco's boot arms the board's watchdog before the root starts; an
  audit of Fiasco's asynchronous-error and interrupt paths. Exit
  criteria: a probe records whether the Raspberry Pi 4's firmware offers
  SMCCC's workaround call, the entry makes the mitigation the CPU and
  firmware allow, the null-request bench is recorded before and after,
  and the patch is carried only if the bench shows no measurable cost; a hang injected in Fiasco's boot before the root's first
  instruction resets the board, under the QEMU harness and once by hand
  on the Pi 4; the audit is a research record naming each path read and
  what it found, and each finding is fixed or a clause of FD33; an
  interrupt storm on a driver's line and an asynchronous error a device
  raises run in the hostile suites' Fiasco set and report what they end,
  and a case that ends another domain or the machine is fixed or is
  FD33's recorded clause.
* **F5, Fiasco's scheduler stages** (FD16 closed; FD15 and FD31 closed
  if stage 5 fits). Status words, deferred preemption, group park in the
  kernel and group quotas, in that order, each a contained change to the
  fork with its policy in erXos's C17 cores
  ([design-fiasco.md](design-fiasco.md#stages-beyond-bands)); urgency
  within a band waits for a consumer or for the urgency-change rate of
  [todo-performance.md](todo-performance.md). Exit criteria: each of
  the first three stages is kept or dropped by its before-and-after
  numbers on Fiasco over the workloads G8 names (E-S1, E-S3 to E-S9), as
  M8 keeps the ladder's features; group quotas either land, with a
  domain spinning on every CPU of its band held to its grant while a
  neighbour in the same band keeps its share, a client's flood held to
  its server's admission, and CPU use per domain reported, or a record
  shows that they do not fit as a scheduler variant and names the
  Fiasco files they would have to change beyond the variant's own,
  `context.cpp` in particular.
* **F6, budgets with caps** (FD25 narrowed; 600 to 1,500 lines). The
  root keeps user pages in the C17 budget core (`kernel/core/budget.c`)
  instead of wall-only records: caps above guarantees, borrowing within
  a domain's wall, a resize of the whole, a watch and exact `used`;
  kernel memory's `used` is read from Fiasco's quota. Kernel memory
  stays a share fixed at a budget's creation unless a consumer is
  refused for it. Exit criteria: a program is admitted while its
  session has memory free in another part; a domain's walls still refuse
  at their guarantee, and the wall test of
  [design-fiasco.md](design-fiasco.md#verification) passes unchanged;
  every budget reports exact `used`, kernel memory included; the budget
  core's host tests and fuzz target pass under ASan and UBSan in the
  form the root links.
* **F7, a pager in the root under track Q's first consumer** (FD9
  narrowed; what FD17 costs measured; 2,000 to 5,000 lines). The root
  serves paged objects and copy-on-write children as their pager,
  Fiasco's own way, as L4Re's `moe` serves dataspaces, and track Q's
  first consumer runs over it: copy-on-write `fork` or a shared file
  mapping written back at `msync` ([Track Q](#track-q-the-second-tier)).
  Exit criteria: that consumer's criteria of track Q pass on Fiasco;
  GQ's measurement of it (`tools/erx bench fork` or `tools/erx bench
  mmap`) is recorded on Fiasco with the fault latency through the root
  and the root thread's share of its CPU, and both again while a hostile
  domain floods the root with faults; the research record says whether
  the root's one thread is the limit and estimates what a root with
  worker threads at each caller's band (FD17) would change.

**Gate GF: Fiasco or erXos's kernel.** Sits after 0.2 and stages F1 to
F7, with group quotas landed or recorded as not fitting. It weighs:

* the downsides table as it then stands: each row left, classed as one
  Fiasco can close (with its estimated cost there: a root with worker
  threads for FD17, gates that carry messages for FD3, umtx across
  spaces for FD22, a whole-space hold for FD21, an exit notifier for
  FD20, a kernel trace ring and watchdog for FD26, the rest of FD13 and
  FD14) or one only erXos's kernel closes (memory objects with no pager
  for FD7, FD9 and FD11; no root tables, the residue of FD14, FD17 and
  FD20's bound; and FD24's construction rules), and whether each of the
  latter is acceptable as a permanently published downside;
* the cost of closing the rows left on Fiasco against what erXos's
  kernel still costs, its estimate recalibrated from GK1's pace and the
  C17 cores already written, counting what the kernel must re-earn that
  Fiasco has (SMP, the interrupt controllers, each board's bring-up,
  the IOMMU drivers) and what it removes (the Fiasco backend, the root's
  tables, the upstream watch, ownership of a C++ kernel's security
  fixes);
* F7's measurements: whether the root as pager, or the root's one
  thread, is a measured problem for track Q's workloads that worker
  threads in the root would not fix, which is the memory model and only
  erXos's kernel changes;
* F5's result: whether group quotas fitted as a scheduler variant;
* the system-call fuzz campaign's and the upstream watch's findings
  since 0.2: how many defects in Fiasco a domain could reach, and
  whether their rate falls;
* whether a release or a consumer needs to claim a construction
  property of FD24 (a proof, an audit requirement, a commitment to
  someone outside the project), which Fiasco cannot give at any price.

It decides one of two courses. erXos's kernel: track K's kernel in full
starts at GK2, and Phase 2 follows as this plan gives it. Fiasco: the
rows Fiasco can close become stages of track F, the rows only erXos's
kernel closes stay published downsides under
[Fiasco's release contract](design-fiasco.md#contract), and the plan's
Phase 2 is rewritten around Fiasco. The measurements go into a research
record and the decision into [design.md](design.md), since it shapes
every subsystem.

**What continues before GF, and what waits.** Track K's pilot and its
host-built C17 cores continue: Fiasco links them as `erx_cores.a` (the
budget core in the root under F6, the scheduler core under F5's group
quotas), and they are erXos's kernel's cores if it is built; with them
continue the CBMC pilot over those cores and GK1's calibration, which
GF uses. `abi/erx_abi.txt` and its generators stay the one source of
the ABI for `liberx`, its backends and Erlang, the hosted and Fiasco
backends keep passing one test set, and the conformance roster grows
with it. [design-kernel.md](design-kernel.md) and the other design
documents stay whole, as the target. What waits for GF is track K's
kernel in full (GK2: the execution model, SMP, the architecture layer,
`liberx`'s `erx` backend), M7, and the parts of Phase 2 that stand on
M7.

## Track K: erXos's kernel

**Goal.** erXos's own C17 kernel, implementing first the interface the
Fiasco backend implements and then the rest of the interface, from
[design-kernel.md](design-kernel.md). The pilot continues whatever gate
GF decides; the kernel in full waits for GF to choose it
([Track F](#track-f-fiasco-improved-to-the-decision)).

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
* **The kernel**, from gate GK2, after the pilot, after 1b-A and after
  gate GF has chosen erXos's kernel, with
  Phase 1's and 1b-A's tests and benchmarks baselined on Fiasco and
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
  decisions in C17 cores ([design-kernel.md](design-kernel.md)):
  capabilities with generations and per-type rights, and budgets with
  guarantees, caps and walls (K32), as space banks, whose deletion
  deletes every object charged to them; spaces with their parents, fault
  gates and labels fixed at creation, threads, memory objects, W^X, and
  exit records that arrive only once no thread of the space can run
  (K18); IPC gates, a server running at its own urgency and on its own
  group's grant from its first instruction; IRQ objects, passing with
  `TRIGGER` and never with `BIND`; umtx, the early console, the time page,
  entropy and `erx_machine_end`; the root task
  ([design-kernel.md](design-kernel.md#the-root-task)); the watchdog and
  the crash record ([design-kernel.md](design-kernel.md#the-watchdog));
  groups in configuration C0, with the quota pool's C17 core built and
  tested on the host
  ([design-scheduler.md](design-scheduler.md#park-and-wake)); and above
  the kernel, `liberx`'s `erx` backend, the domain library's production
  `erx_dom_plan_configured`, which the packer runs as its property-12
  checker ([design-system.md](design-system.md#the-domain-library)), and
  the production startup plan `erx_root_plan` with its charge evidence,
  which replaces the Phase 1 root startup rule behind the packer's
  `Admitted` value before gate GK3
  ([design-kernel.md](design-kernel.md#the-startup-plan-and-its-charge-evidence));
  the conformance suite for every call in scope; the chokepoint checks
  that confine kernel calls to `liberx`; the stack proof and chokepoint
  checks over the C17 cores. Capability transfer at an IPC rendezvous
  lands in M5's kernel part, with this IPC designed to add it without
  reshaping the rendezvous.

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
* **Deferred guarantees.** Every guarantee Phase 1 and 1b defer that
  track F does not close lands on erXos's kernel at the milestone named
  in [design-fiasco.md](design-fiasco.md#downsides-against-erxoss-kernel).
* **The switch**, at gate GK3: the conformance suite, Phase 1 and 1b's
  transcript tests, the oracle and the benchmarks run on both kernels,
  differentially ([M7](#m7-fiasco-leaves)). Fiasco carries only
  Phase 1 and 1b's part of the interface, so the switch waits for nothing
  beyond Phase 1 and 1b's system. Each row the backend grows for Phase 1b
  names what the kernel's first part must implement by the switch, and a
  vCPU row, if Fiasco gains one, brings vCPU upcalls into the first
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

## M7: Fiasco leaves

**Goal.** erXos's kernel boots 0.2's system and replaces Fiasco.

**Demo.** The same boot image boots on erXos's kernel and runs 0.2's
system: the system shell and the live machine, files from EROFS
and littlefs, the Erlang command shell, domains over their connections,
programs over pipes, the POSIX-lite first part, the browser and the
desktop, drivers in their domains, erXos's F2FS and the network stack on
QEMU, and whatever else 0.2 took, with every test and benchmark it ran on
Fiasco.

**Exit criteria.** Every conformance, transcript and oracle difference
between the two kernels, the transcripts compared from erXos's banner on,
is a bug fixed, a documented improvement with a test, or a bug in
Fiasco recorded as such, K26's "at once" among the improvements; the
scheduler and messaging benchmarks meet or beat Fiasco's; a page-table
walk after every test finds no writable and executable mapping.

**Gate GK3.** Decides the replacement, from the conformance suite and
0.2's workloads: parity over 0.2's system, which is all Fiasco carries, as
replacing Fiasco or a stopgap needs. Both kernels may then stay
supported for a while, each a backend behind the same kernel interface;
once erXos's kernel has replaced it, the fork leaves the tree with its
`TODO.md` item, and with it what
[design-fiasco.md](design-fiasco.md#what-erxoss-kernel-keeps-and-drops)
drops; the dependency table drops it.
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
devices; DMA confined behind the IOMMU. M9 lands in two parts: on
Fiasco as 1b-E, after 1b-A, and its kernel part on erXos's kernel, after
M7.

**Demo.** A block transfer and a network ping run while the block driver
process and then the network driver process are killed; each supervisor
resets its device and restarts the driver; the shell never notices. The
inspector shows every driver as a process with its device's registers by
name. On Fiasco the drivers run over virtio-mmio, unconfined, and a
block driver restarts only with its domain: its kill ends the storage
domain, `/data` is unavailable until the domain's restart has reset the
device and mounted the volume again, and every synced file is present
([design-stopgap.md](design-stopgap.md#littlefs-in-the-storage-domain)).
The network driver restarts in its domain under a TCP connection of
root's session, which echoes again once the link has its lease, and the
ping runs from root's session through the network domain's `net` grant.

**Scope, on Fiasco (1b-E).** The storage domain, which holds the block
driver and the file systems from here, with littlefs as a NIF
([design-stopgap.md](design-stopgap.md#littlefs-in-the-storage-domain));
the device service in full, with the system manifest's placement of
devices and its `/dev` tree ([design-system.md](design-system.md#devices));
the device NIF in full, receive copied into a fresh binary at completion
so that no term aliases memory the device can write, with the build check
that register accessors are referenced only from the device NIF
([design-runtime.md](design-runtime.md#the-device-nif)); the block and
network drivers in Erlang over virtio-mmio, in the storage and network
domains that hold their devices, unconfined, written after sDDF's model
of the driver-versus-policy split, with sDDF's published throughput as
the oracle and nothing imported; the restart demo. The GPU and input
drivers come with the display domain of track D's part 3
([track D](#track-d-windows-widgets-and-the-web)). Drivers run in their
own domains rather than the system domain, since that is the structure a
person sees and the device service's first real exercise; the unconfined
DMA residual is the same either way. No task other than the root creates
a device object: the domain library creates each device's objects in the
root, passes them to the holder, and at the holder's end keeps the memory
for the restarted holder
([design-fiasco.md](design-fiasco.md#device-records)). DMA stays
unconfined, since QEMU `virt` as the harness starts it has no IOMMU, and
the Phase 1 manifest check allows these devices in development builds
([design-fiasco.md](design-fiasco.md#the-phase-1-manifest-check)).

**Optional on Fiasco.** The host-tree domain of
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
placement and `/dev`, the supervisors and the tests. [Track
U](#track-u-usb)'s part (b) builds the PCIe enumerator and the MSI
frame's use on Fiasco first; M9's kernel part moves them onto erXos's
kernel, whose kernel drives the frame.

**Exit criteria, on Fiasco (1b-E).** A storage domain killed under
load restarts with no acknowledged write lost; a littlefs failure ends the
storage domain, which restarts and remounts with no acknowledged write lost;
driver restarts under load
lose no acknowledged data, and a device reset after a driver's crash
returns every posted buffer to its pool; the drivers' descriptor parsers
survive their fuzz budgets; a hostile device model under QEMU writing
malformed descriptors
and completions crashes at most the driver process and never the runtime;
`/dev` reads every device's status, and only the control facet's tree
accepts `ctl` writes; the chokepoint check over the register accessors
passes with its seeded violation.

**Exit criteria, on erXos's kernel (M9's kernel part).** Every criterion
of Fiasco's list passes again over virtio-pci; a confined driver
cannot DMA outside its window; a device given to a second domain while
the first holds it is refused; the PCIe enumerator's fuzz target runs its
budget clean; MSIs reach every virtio-pci device under HVF.

**Gate G9.** Measures, per device class, interrupt-to-handler latency
through the runtime's scheduler with `tools/erx bench irq`, the ring
throughput of each driver against sDDF's published figures for the same
device, `tools/erx bench blk` and the network driver's packet rate, and
the MSI path under HVF against wired interrupts. On Fiasco, in 1b-E,
its measurements are recorded with Fiasco named and decide nothing:
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
decided from Fiasco's numbers.

## 1b-G: Networking on QEMU

**Goal.** Networking to other machines on QEMU `virt`, on Fiasco,
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
([design.md](design.md#networking)); `crypto`, `asn1`, `public_key` and TLS on OpenSSL
3.5, in the interpreter and BeamAsm images, the system image without it
([design-crypto.md](design-crypto.md)); and SSH's first two stages
([design-ssh.md](design-ssh.md#stages)): OTP's daemon with its edits in
root's development session, then the SSH domain, its login facet with
its cookies and derived session identifiers, `erx_tty_line` with its
ttys and jobs, and the channel and algorithm policies and limits, for
`root` and the development key in development builds. No stopgap stack is ported: the stack is erXos's own from the first,
written in Erlang by translating the logic of FreeBSD's `netinet` and
`netinet6` at one pinned release, as the network stack's design document
specifies. Sockets are the oracle's last family that cannot
run, so 1b-G closes the full oracle on QEMU. The network domain's own
grant and its per-interface ingress budget are guarantees of erXos's
kernel, recorded as residuals here and checked on the boards with M12.

**Exit criteria.** The packet path and the Internet checksum run their
fuzz budgets clean; the oracle's socket cases run on erXos and compare
with stock OTP 29.1.2 case by case; M14's criteria for its first stage
hold on QEMU; the system image's link list names no `libcrypto`, and a
link given `crypto`'s table beside it fails; `crypto`'s, `public_key`'s and
`ssh`'s suites agree with stock OTP 29.1.2 through `check-oracle`; and
SSH's QEMU interop, algorithm-policy, jobs, limits and hangup tests of
[design-ssh.md](design-ssh.md#verification) pass, with `ssh -p 2222
root@localhost` from the host's OpenSSH client reaching `rc`, and the
`erx_ssh_wire` fuzz target runs its budget clean.

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
peer progress under load on matched setups. On Fiasco every
interrupt, acknowledgement and doorbell passes the backend's one service
thread, so these numbers are a baseline, recorded with Fiasco named,
and decide nothing: a native fast path admitted on them would work around
Fiasco rather than the stack. M14 is written in Erlang throughout
meanwhile. GK3 repeats the measurements on erXos's kernel and decides
there whether TCP's fast path in erXos's stack needs native code
([design.md](design.md#networking)); GN-board at M12 confirms or reopens
that decision on the Pi 4.

## 1b-I: The Raspberry Pi 4 on Fiasco

**Goal.** The Raspberry Pi 4 Model B runs Phase 1 and 1b's system on the
Fiasco, so the first board is usable before erXos's kernel
exists, along [design-platforms.md](design-platforms.md#raspberry-pi-4-model-b)
and Fiasco's shape on the board in
[design-fiasco.md](design-fiasco.md#the-raspberry-pi-4). A board is
data: the Pi adds a platform record, a manifest, a `bootstrap` build, its
boot files and Erlang drivers, and no interface changes. M12
stays the boards' milestone on erXos's kernel: it adds the kernel's
platform items, system updates and the guarantees to what this item
brings.

**Demo.** The Pi boots from its firmware, over the network or from its SD
card, to the shell on its console; a file synced under `/data` on the SD
card survives a power cut; the network domain carries UDP echo and a TCP
bulk transfer to a peer over the Pi's Ethernet, and over WiFi once the
Pi has joined a WPA2 or WPA3 network; the LVGL dashboard of
[1b-C](#track-d-windows-widgets-and-the-web)'s part 4 shows on the Pi's
screen; a real-time clock module on the header keeps the time across a
power cut. Every guarantee is deferred, as on QEMU. An LED on the header
that lights from the shell, and a button that wakes a read of its
`event` file, join the exit once part (e)'s GPIO package can be built
(below).

**Decided.** The port runs on Fiasco. The firmware boots the
single bootable file directly as `kernel8.img`, with TF-A's BL31 as the
armstub and no U-Boot, as [design-platforms.md](design-platforms.md#firmware)
has it. The console is the mini UART, which `enable_uart=1` puts on the
header's GPIO 14 and 15 and whose core clock it pins, and which the
card's device tree names `serial0`, where BL31 points
`/chosen/stdout-path`; the host link is
UART3, a PL011, for the reasons
[design-platforms.md](design-platforms.md#raspberry-pi-4-model-b) gives,
driven by `erx_pl011` as on QEMU `virt`. Stage (a) is developed on QEMU's
`raspi4b` model and first proven there, under TCG, and then passes once
on a board before it counts as done; stages (b), (c) and (d) are proven
on the board
([design-platforms.md](design-platforms.md#bring-up-under-qemu) lists
what the model cannot check). The Pi has no input device: no USB
keyboard, since the Pi 4's USB host sits behind the PCIe bridge, whose
driver is [Track U](#track-u-usb)'s, so input comes over the serial
console or the web front end over the host link. Drivers are Erlang,
programmed I/O first where the device allows it. The kernel's platform
items of M12, the hardware watchdog, the crash region, trial boot and the
device secret, are deferred as Phase 1
residuals ([Downsides against erXos's kernel](design-fiasco.md#downsides-against-erxoss-kernel)).
The random generator is not: the root reads the Pi 4's RNG200 on the
condition of [design-platforms.md](design-platforms.md#entropy-sources)
([design-fiasco.md](design-fiasco.md#the-raspberry-pi-4)), once the
RNG200 facts record exists; the board's hand test checks that the
banner names it as the source.

**Parts.** Each ends in a demo reproduced on the board by hand; stage (a)'s
also runs on QEMU's `raspi4b` model. Part (a) comes first; (b), (c), (d)
and (e) each need only (a) on the board, and may go in any order or side
by side; (f) needs (b) and (c).

* **(a) A serial shell on the Pi, on QEMU's `raspi4b` first.** The Pi's
  image boots to the shell on the mini UART under `raspi4b` and on a
  board, with the host link on UART3. The BL31 experiment on the model is
  [research-rpi4-bl31-qemu.md](research-rpi4-bl31-qemu.md), the board
  pass and boot probe
  [research-rpi4-board-pass.md](research-rpi4-board-pass.md), and the
  harness's configuration
  [design-platforms.md](design-platforms.md#bring-up-under-qemu).
* **(b) Storage on the SD controller.** An Erlang driver for the Pi's SD
  host controller (`brcm,bcm2711-emmc2`, an SDHCI controller) as the
  block driver's device process, by programmed I/O first, then DMA once
  the device NIF cleans and invalidates for a device that is not coherent.
  It rests on the block driver's split into a transport and the service
  above it, so the Pi adds a device process and nothing above it moves,
  and the write path's rule (U4) holds across the split
  ([design-storage.md](design-storage.md#the-sd-host-controller)). The
  storage domain holds the SD card, laid out as the ABI file's medium
  layout, with the slot's system partition served as the `system` tree
  and littlefs at `/data`; fsimg's `place` option writes the record
  partition's FAT16 and slot A's FAT32 with their placed files
  ([design-platforms.md](design-platforms.md#slots-and-the-boot-selection-record));
  each DMA device's entry in the platform record carries its bus offset
  and reach ([design-fiasco.md](design-fiasco.md#the-raspberry-pi-4)).
* **(c) Network on GENET.** An Erlang driver for the Pi's Ethernet
  controller (`brcm,bcm2711-genet-v5`) and its PHY, in the network
  domain, under 1b-G's network service and stack. GENET moves packets
  only by DMA, so this stage needs the device NIF's cache maintenance
  from its start. The packet path's numbers are recorded on the board as
  a baseline that decides nothing; GN-board decides at M12. SSH's third
  stage, its second over the board's Ethernet
  ([design-ssh.md](design-ssh.md#stages)), comes with this part.
* **(d) Display on the firmware's framebuffer.** The display domain over
  the `simple-framebuffer` the firmware sets up, with the firmware
  framebuffer driver of track D's part 4 brought forward onto
  Fiasco, and 1b-C's kiosk drawing on it. The framebuffer is a
  long-lived region the device scans out, filled by rectangle with
  `erx_device:fill/3`. Panels, touch, keypads and encoders stay with
  part 4.
* **(e) The header: I2C, SPI and GPIO**, along
  [design-header-io.md](design-header-io.md). Its packages:
  1. **The header map.** The platform record's `pins`, its pin
     controller and rows, and `hw/pins/bcm2711.txt` from the
     datasheet's Table 94 with its controllers' signals; the record
     reader's checks of the map; `config.txt`'s `gpio=` lines,
     `enable_jtag_gpio` and `core_freq` generated from it, replacing
     `OVERLAY_PINS`; property 8's pin-controller clause with its
     seeded manifest; the units `i2c` and `spi`, their device-kind
     rows and roles and their CMSIS-SVD files; and the devices domain
     on the Pi's development manifest, with `gpio` given to no
     domain. One package, since every later one reads these files.
  2. **I2C and the clock module**: `erx_bsc_core` with its repeated
     start and stall limit, BSC1's driver, `/dev/i2c1`, and
     `erx_rtc` with `/dev/rtc` granted to the system domain.
  3. **SPI**: `erx_hold`, `erx_spi_core` with its held transfer,
     SPI0's driver and `/dev/spi0`; the vault's TPM driver uses the
     same core, with its wait-state framing, along the vault's TPM
     design. Packages 2 and 3 each need only package 1, and go side
     by side.
  4. **Pins and GPIO**, along
     [design-pinctrl.md](design-pinctrl.md), in the system domain;
     nothing else in (e) needs it: the pin table with pulls and
     states, the manifest's `pins` table and the `pins` record, the
     `gpio` unit's kind row and SVD, and `erx_pins` with its
     `bcm2711` kind, which sets every device's pins at its start,
     takes over the root's boot write and ends `config.txt`'s `gpio=`
     lines; then `/dev/gpio` with its
     `gpio` interface and `pins` parameter, and the LED and button.

  PWM is not a package of 1b-I. It is built when a consumer needs
  it, along the design's PWM section, starting from the boot probe's
  reading of whether the firmware leaves the PWM clock running.
* **(f) WiFi on the CYW43455.** The Pi's WiFi chip on the legacy SD
  controller, along [design-wifi.md](design-wifi.md): the storage
  domain's SDIO host serves the card through `sdio`, the WiFi domain
  drives the chip and runs the station, a choice, a join machine and
  a failure memory with the supplicant, a key holder answers each
  join's secret steps, and the
  network domain carries `wlan0` over the medium the WiFi domain lends
  through `ether`. The fetch step pins the Cypress firmware, NVRAM and
  CLM files, and the Pi's image carries them in the WiFi application's
  release. Its packages, in order, each proven on the board by hand:
  1. **W0, the SDIO card up.** The legacy controller's `sdio sdhci`
     record, `erx_blk_write`'s SDIO table, the SDIO host and the `sdio`
     interface; the boot log names `CYW43455 rev N`. The power and pin
     facts of [design-wifi.md](design-wifi.md#facts-this-design-does-not-have)
     are settled here, by the board probe or a clean-room facts record.
  2. **W1, firmware running.** Firmware, NVRAM and CLM loaded and read
     back, `ver`, `cap` and the hardware address in the log and at
     `/proc`, and `wlan0` offered to the network domain with its link
     down, through `ether` and `erx_net_ether`.
  3. **W2, scan.** The seam to the chip in 802.11's management
     requests; `ifconfig wlan0 scan` lists the test access point in
     FreeBSD's columns, and `/proc` shows each BSS with its verdict.
  4. **W3, an open network.** The choice and the join machine with
     its transition table; DHCP, ping, UDP echo and a TCP transfer
     over `wlan0`, as (c) runs them over GENET.
  5. **W4, WPA2-PSK.** The key holder's two interfaces with the
     development holder behind them; the 4-way and group handshakes on
     the host, each PTK asked of the holder, each key installed once,
     a group rekey survived; the network's secret given with root's
     `wlankey`, which derives in the session; the failure memory, with
     a wrong passphrase shown as `secret_failed`.
  6. **W5, WPA3-SAE with PMF.** OTP `crypto`'s three SAE functions
     behind the holder, SAE with hash-to-element through the
     firmware's external authentication, PMF, and the Transition
     Disable mark; it needs the firmware's `sae_ext` capability,
     which W1 reads, and without it WPA3 is reported unsupported.

  The key holder's release form is a purpose of the vault
  ([design-wifi.md](design-wifi.md#decisions), 1); W0 to W5 are built
  on the development holder behind the same two interfaces.

**Dependencies.**

* (a): Phase 1's shell; QEMU's `raspi4b` model, which the local QEMU
  11.1.3 has; for its board pass, a 4 GB board.
* (b): (a); 1b-E's storage domain; the block driver's split into
  transport and service; for DMA, the device NIF's cache maintenance for
  a device that is not coherent (`TODO.md`, `erx_device.c`, queues).
* (c): (a); 1b-E's network domain and 1b-G's network service; the
  device NIF's cache maintenance, as for (b).
* (d): (a); 1b-C's part 3, the display domain, and part 4b's LVGL
  dashboard; the device
  NIF's region call, `erx_device:fill/3` (`TODO.md`,
  `docs/design-display.md`).
* (e): (a); 1b-E's configured domains, for the devices domain; for
  the TPM, the vault's TPM design and a module on the board.
* (f): (b)'s storage domain on the board; (c)'s network domain on
  the board; for W5, the firmware's `sae_ext`, or another licensed
  Cypress build that offers it
  ([design-wifi.md](design-wifi.md#sae-and-protected-management-frames));
  a test access point offering open, WPA2 and WPA3 networks: hostapd
  2.12 started by the harness with the design's profiles on a host
  with a radio, or until one serves, a commodity router set by hand.

**Testing.**

* **QEMU's `raspi4b`, under TCG, proves stage (a) first.** Agents
  develop stage (a) on it, and its suite runs with the landing gate when
  the Pi's image or its boot changes: the Pi's image, loaded as the harness
  configures it, boots to the shell's prompt on the mini UART with the
  development banner, and the console transcript of the production image
  suite's cases (a sum, a line with a mistake rubbed out, an output
  longer than the transmit FIFO) passes there; the seeded fault, a
  mini-UART driver that drops one received byte, fails the sum. The suite
  also checks that four CPUs run, with the
  seeded fault a device tree with one CPU's node removed, which
  shows three, and that a reset ends QEMU under `-no-reboot`.
* **What the model cannot check**, and the board must: the firmware
  path, which runs on the VideoCore and which QEMU does not emulate
  (`config.txt`, the firmware's edits to the device tree, where it
  places the device tree and the bootable file, the entry state it
  leaves, and the size of bootable file it accepts); the host link, since the model
  has no UART3; the mini UART's baud rate, since the model's mini UART
  takes no clock; cache coherency, since QEMU's DMA is coherent and a
  missing clean or invalidate passes there; and GENET and PCIe, which
  the model lacks
  ([design-platforms.md](design-platforms.md#bring-up-under-qemu)). So
  stage (a) passes once on a board before it counts as done, and stages
  (b), (c) and (d) are proven on the board alone.
* **Board suites run once per batch and at the milestone gate**, not per
  commit, under the same harness, deadlines and transcripts as QEMU's;
  agents iterate on host tests, the hosted backend, QEMU `virt` and, for
  stage (a), `raspi4b`.
* **The manual board pass.** The board is a 4 GB Raspberry Pi 4. There
  is no automated rig: the build produces the SD card's image, and the
  transcript checks and the power-cut checklist are run by hand on the
  board, power being cut by pulling the supply. An automated rig
  (serial capture, power relay, SD card switch) is not part of 1b-I.
* **The power-cut checklist.** A write load on the board writes files
  under `/data`, syncs each, and prints a numbered mark on the console
  once each file's sync has returned, naming the files synced so far.
  Power is cut by hand just after a mark, ten times, the cuts spread
  over the load's marks from first to last; after each, the board is
  powered back on and the next boot lists `/data`. For each cut the board pass's record
  lists the mark it followed and, for each file synced before it,
  whether the file survived whole; every synced file must.
* Every parser of what a Pi device writes (the SD controller's responses
  and status, GENET's receive status and descriptors, and for (f) the
  SDIO responses, every format of the WiFi chip and the air, and
  `wpa_supplicant.conf`) lands with its fuzz target, as the ground rules
  require.
* **The header's checks** are
  [design-header-io.md](design-header-io.md#verification)'s: the pure
  cores on the host, each case with its seeded fault; the `raspi4b`
  suite's cases on BSC1 with an emulated clock chip, SPI0 with an
  emulated flash and, with the GPIO package, the model's GPIO, whose
  first run records which of them the model supports; and the board
  checklist with its loopback jumpers, run by hand once per package.
* **WiFi off the board.** QEMU has no WiFi device. (f)'s cores run on the
  host against recordings, published vectors and wpa_supplicant and
  hostapd 2.12, WPA2's on the FreeBSD x86-64 test host and SAE's on the
  Linux test access point, since hostapd's BSD driver carries no SAE
  frames; a fake chip behind the
  `sdio` interface runs the WiFi domain in hosted mode and on QEMU
  `virt`, where the network stack's suites run over `wlan0` unchanged
  and the station's scenarios run against a scripted air
  ([design-wifi.md](design-wifi.md#verification)).

**Exit criteria.**

* (a): on `raspi4b`, the Pi's image boots to the shell on the mini UART
  and passes the console transcript, and fails it with the seeded driver;
  the host test of the record against the board's device tree passes, and
  fails on a record with one window moved; once, by hand on the board,
  the Pi boots from its firmware to the shell on the mini UART with the
  development banner, the host tool reaches it over UART3, and the boot
  probe's research record is written.
* (b): QEMU's block suites pass unchanged after the split; by hand on
  the board, the power-cut checklist passes: in each of the ten cuts
  every file synced before the cut's mark survives whole, and the board
  pass's record lists each cut with its mark and the files that
  survived; a storage domain killed under load restarts with every
  synced file present; the seeded write of a request not built by
  `erx_blk_write`, a virtio post or an SD command, fails the build
  check, and a write of the command register through
  `erx_device:write/3` answers `badarg`; the SD controller's parsers run their fuzz budgets
  clean.
* (c): UDP echo and a TCP bulk transfer to a peer pass on the board; a
  network domain killed under load restarts ending only its
  connections; GENET's parsers run their fuzz budgets clean; the packet
  path's numbers are recorded with the board named; by hand, `ssh
  root@` the board with the development key reaches `rc`, and a 1 MiB
  `ssh -T board cat` passes through unchanged.
* (d): the frame in the Pi's framebuffer, read back through the display
  driver, equals the frame the same kiosk draws on QEMU `virt`; a
  display driver killed and restarted repaints the screen.
* (e): the header map reader refuses each of its seeded maps, and the
  manifest check refuses the manifest that gives `gpio` to the
  devices domain; on `raspi4b`, the clock chip's time written through
  `/dev/rtc/time` reads back, a missing I2C device answers `eio`, and
  a second session's open of a held chip select answers `ebusy` until
  the first ends, each case failing with its seeded fault; by hand on
  the board, the SPI loopback passes, the clock module keeps the time
  across a power cut, the boot probe's register values and the GPLEV
  check are recorded, and SCLK measured with an instrument agrees
  with the record's core clock within 1%, or is recorded as
  unmeasured; the `ctl` grammars and the clock chip's decoder run
  their fuzz budgets clean. With the GPIO package, the GPIO loopback
  passes and the LED and button answer the shell.
* (f): on the board, W0's and W1's log lines; no scan before a country
  is configured; a scan listing the test access point; DHCP, ping, UDP echo and a TCP transfer on the open, the
  WPA2 and, given `sae_ext`, the WPA3 network; a wrong passphrase shown
  as `secret_failed` at `/proc` and joined once the right one is
  given; the WiFi domain killed under load joining
  again while `genet0` carries on; a 64 MiB write to `/data` beside a TCP
  transfer over `wlan0`, both completing; (b)'s power-cut checklist
  passing with WiFi under load. Off the board, the join machine's
  exhaustive exploration, which takes every edge of its table and no
  other, retransmitted and replayed key messages among its events,
  the choice's properties, the key holder's tests,
  the Annex J and J.10 vectors, the differential against wpa_supplicant's
  recordings, the scenarios against the scripted air and the network
  stack's suites over the fake chip pass, each
  failing on its seeded fault; the WiFi parsers run their fuzz budgets
  clean.

**Gate GR, before the first board boot.** The board is a 4 GB
one, with no automated rig; the answers are recorded in
[design-platforms.md](design-platforms.md). Nothing above depends on
the RAM size: the platform record names the smallest RAM the port boots
on, at most the 2 GiB of the `raspi4b` model, so one image boots on the
model and on every board. Measures, through the boot probe, where the firmware places the
bootable file and the device tree, the entry state, the memory map,
whether `stdout-path` names the mini UART, where the framebuffer lies,
and the time to the system runtime's first pet.

## 1b-J: The Raspberry Pi 5 on Fiasco

**Goal.** The Raspberry Pi 5, a 4 GB board, runs Phase 1 and 1b's system
on Fiasco, as 1b-I brings up the Pi 4, along
[design-platforms.md](design-platforms.md#the-raspberry-pi-5-on-fiasco),
[design-fiasco.md](design-fiasco.md#the-raspberry-pi-5) and
[design-rp1.md](design-rp1.md). The board is data: a platform record, a
manifest, its boot files, a PCIe bridge driver, RP1's drivers and the
Ethernet driver, and no interface changes. M12 stays the boards'
milestone on erXos's kernel.

**Demo.** The Pi 5 boots from its firmware to the shell on its debug
UART; its Ethernet carries UDP echo and a TCP bulk transfer to a peer
through `cgem0`; a USB keyboard on either of RP1's hosts types into the
shell and a USB stick mounts; the kiosk shows on its screen once the
display's part can be built (below). Every guarantee is deferred, as on
the Pi 4.

**Decided.** The port runs on Fiasco, on the Pi 4's kernel build and,
unless the probe shows otherwise, its `bootstrap` build. The firmware
boots the single bootable file as `kernel_2712.img` through its own BL31,
so no TF-A is shipped; `config.txt` adds `os_check=0` and
`pciex4_reset=0` and names no `armstub`. The console is `uart10`, the
BCM2712's own PL011; no host link, as
[design-platforms.md](design-platforms.md#raspberry-pi-5) has it. The
first boot comes before a serial cable is wired, so it is judged by the
signs that exist already, with no new mechanism: the firmware's LED
codes and HDMI diagnostics, the display's splash only where the firmware
hands over a framebuffer, and the watchdog's reset loop
([design-platforms.md](design-platforms.md#the-raspberry-pi-5-on-fiasco));
only the splash or the serial banner proves that the kernel ran.
The watchdog is the Pi 4's driver. RP1 is one unit in the `rp1` domain,
which lends Ethernet to the network domain through `ether` and is the
USB domain of both hosts. Which device tree ships is open
([design-platforms.md](design-platforms.md#the-pi-5s-device-tree-and-its-license));
development boards boot the tree on their card. QEMU has no Pi 5 model,
so every part is proven on the board, its pure cores on the host first.

**Parts.** Each ends in a demo reproduced on the board by hand. (a)
comes first and (b) as soon as the cable is there; (c), (d) and (g) need
(b); (e) needs (d); (f) and (h) need (e).

* **(a) The card and a headless first boot.** `config/platforms/raspi5.json`
  and `config/manifest/raspi5-development.txt`; the boot partition writer's
  Pi 5 lines; the Pi 4's card layout. The firmware's screen showing the
  kernel file loaded is recorded as "loaded, execution unverified": a
  kernel that hangs before the root arms the watchdog leaves the board
  as quiet as one that runs (FD29), so (a) proves the card, not the
  boot.
* **(b) The serial console and the boot probe.** The shell on `uart10`,
  the first proof that the kernel runs, and the boot probe's research
  record, `research-rpi5-board-pass.md`, with (b)'s probe items below;
  each later part adds its own items to the record.
* **(c) Storage on the SD controller.** `sdio1` as the block driver's
  device process, as
  [design-storage.md](design-storage.md#the-raspberry-pi-5s-controller)
  gives it: the Pi 4's driver with the Pi 5's record.
* **(d) The bridge and the MIP.** `erx_pcie_bcm2712` with its keep-only
  start, kept layouts, the walk's device-0 rule, the MSI frame's doorbell,
  data and start writes, and several messages per function
  ([design-pcie.md](design-pcie.md#the-bridge-seam)); RP1 is enumerated
  and each part's entry raises its line.
* **(e) RP1's unit.** Part rows, `erx_rp1` with its clocks read first, the
  MSI-X configuration, the vector's acknowledge in the NIF, mastering
  after every part's reset, and the hosts' cores held in reset while no
  part names them
  ([design-rp1.md](design-rp1.md#the-construction-a-function-and-its-parts)).
  The platform record lists `eth` from (f) on and the USB parts from
  (h) on, each with its driver, so Ethernet needs nothing of USB.
* **(f) Ethernet.** `erx_cgem`, the GEM ring form, `cgem0` lent through
  `ether` ([design-rp1.md](design-rp1.md#the-ethernet-controller)); then
  SSH's stage 1 over it as on the Pi 4.
* **(g) The display.** The kiosk on the firmware's framebuffer, as on
  the Pi 4, if the probe finds one in the tree the firmware passes; if it
  does not, this part waits for a display design for the Pi 5.
* **(h) USB.** The parts `usb0` and `usb1`, the DWC3 step and both hosts
  under the xHCI stack ([design-rp1.md](design-rp1.md#the-usb-hosts)).

**Dependencies.** (a) and (b) on 1b-I's part (a) and the platform's
record format; (c) on 1b-I's part (b); (d) on the PCIe design's
implementation in 1b-E; (f) on 1b-G
and WiFi's `ether` interface; (g) on 1b-C's part 3; (h) on Track U's part
(a). Nothing in 1b-I waits on this stage.

**Testing.** Host tests and fuzz targets of the cores, each with its
seeded fault, as [design-rp1.md](design-rp1.md#verification) and
[design-pcie.md](design-pcie.md#verification) list them: the BCM2712
start's decision, kept layouts, the walk's rule, several messages, the
packer's MSI frame, the doorbell's bus address, `erx_rp1_core`'s clocks
and vectors, mastering, the vector's acknowledge, a USB part's window,
`erx_cgem_core`, `erx_cgem_mdio`, the GEM ring form and its fuzz target,
the DWC3 step. The board passes are by hand, with a checklist per part,
as the Pi 4's.

**Board probes.** Recorded in (b)'s research record, each result beside
the firmware's version, the `config.txt` it booted with and the tree it
passed, and each with the part that consumes it:

* (b): the load address, the CPU's state at entry, the device tree's
  place, whether `os_check=0` suffices, and whether the firmware's BL31
  prints once the kernel runs; the console's divisor and from it the
  UART's clock; the watchdog: a hang injected after the root arms it
  resets the board within the timeout; the tree the firmware passes:
  `/chosen`, the memory node, any framebuffer node and where it lies,
  the `ethernet0` alias's address;
* (c): the SD controller's items
  ([design-storage.md](design-storage.md#the-raspberry-pi-5s-controller));
* (d): `pcie2` as the bootloader leaves it with `pciex4_reset=0` and with
  the default: the status bits, the inbound windows and UBUS remaps, the
  outbound windows, PERST#; with the link dropped, a configuration read
  and write and a BAR read and write, each bounded and reported; the
  MIP's twelve registers before the root writes them; RP1's snapshot:
  its BARs' addresses and sizes, its MSI-X table's BAR and offset;
* (e): RP1's clocks: the system PLL's lock and dividers, and the `SEL`,
  `CTRL` and `DIV_INT` of `clk_sys`, `clk_eth` and `clk_eth_tsu`; whether
  the GEM and the USB hosts are running at entry; GPIO 32's level; each
  part's entry raised by RP1 through `MSIX_CFG`'s test bit, delivered on
  its line with the data its message carries;
* (f): the GEM's `DCFG6` (64-bit addressing, priority queues) and
  `DESIGN_CFG1`; the PHY's identity, its RGMII delays and the speeds it
  links at; whether transmit resumes at the stopped descriptor; how long
  receive takes to stop, and whether a frame can land after it; under a
  stress of short frames, that each frame's length and status match its
  bytes (the controller's `OWN` after its status) and that receive goes
  on after running out of descriptors; whether RP1's writes through
  `pcie2` are coherent with the CPUs' caches;
* (h): GPIO 42's and 43's function and pads, the ports' VBUS power and
  over-current input.

**Exit criteria.**

* (a): the firmware reports the kernel file loaded, recorded as loaded
  with execution unverified, and a card whose kernel file is renamed
  shows the firmware's error.
* (b): the Pi 5 boots to the shell on `uart10` with the development
  banner, and (b)'s probe items are recorded.
* (c): the Pi 4's power-cut checklist passes on the Pi 5's card.
* (d): the PCIe domain lists RP1 with its kept BARs; a test write of each
  part's message to the MIP's doorbell raises that part's line; the host
  tests pass, each failing on its seeded fault.
* (e): `erx_rp1` starts and logs its readings; the function masters only
  after the GEM's reset, which the log's order shows; a level vector
  held high through `MSIX_CFG`'s test bit across the acknowledge is
  delivered again, and is not when the NIF's `IACK` is left out; a GEM
  driver killed between a delivery and its acknowledge has its
  successor delivered the held-high vector; the host tests pass.
* (f): UDP echo and a TCP bulk transfer to a peer over `cgem0`; under
  traffic, the GEM's driver, `erx_rp1` and the PCIe domain each killed in
  turn, and `cgem0` comes back each time; the `rp1` domain killed under
  load restarts and `cgem0` comes back; a cable pulled and replaced
  brings the link down and up; the GEM ring form's fuzz budget runs
  clean; `ssh root@` the board reaches `rc`.
* (g): the kiosk's frame read back from the framebuffer equals QEMU's,
  where the part can be built.
* (h): a keyboard on each host types into the shell; a USB stick on
  either host mounts and a file written to it reads back after
  replugging.

**Gate GR5, before the first board boot.** The board is a 4 GB Pi 5, with
no automated rig. Measures, through the boot probe, where the firmware
places the bootable file and the tree, the entry state, the memory map
and the console's clock. Decides the RAM the platform record names and
whether the Pi 4's `bootstrap` build serves the Pi 5.

## Track U: USB

**Place.** In Phase 1b, below the first two apps (Track A, "What comes
first"): part (a) runs beside every other item, part (b) follows 1b-E,
part (c) runs beside 1b-I's board work, and part (e) follows (b). Part
(d) is Phase 2's. No milestone depends on the track.

**Goal.** A USB keyboard, mouse or tablet and a USB stick work on QEMU
`virt` and on the Raspberry Pi 4, along [design-usb.md](design-usb.md):
both controllers are xHCI behind a PCIe domain, the controller's domain
holds every USB device, HID reaches the display's input router through
input numbers, and a stick's FAT and EROFS volumes are served at
`/media` through drives ([design-drives.md](design-drives.md)).

**Demo.** On QEMU `virt`, keys typed with QMP into a USB keyboard on
`qemu-xhci` reach a window, a tablet moves its pointer, a keyboard
unplugged with a key held releases it, and a USB stick's sectors are
read and written through a drive; on the Pi 4, a USB keyboard behind
the VL805's internal hub types into the kiosk.

**Parts.** (a) needs nothing new below it.

* **(a) The cores, on the host.** The descriptor decoder, the bus and
  hub cores, the controller core, the HID parser and fold, the BOT core,
  the SCSI builders, the TRB ring form's core and a register model of
  the BCM2711 bridge, with their fuzz targets and explored tests
  ([design-usb.md](design-usb.md#verification)).
* **(b) The PCIe domain and `qemu-xhci` on QEMU `virt`, on
  Fiasco.** The PCIe enumerator with BAR assignment in a `pcie` domain;
  the three PCIe facets, `pci_bus`, `pci` and `pcie`, and the device
  service's PCIe process ([design-pcie.md](design-pcie.md#facets));
  `erx_domain:await_grant/2`; the domain library's intake of the
  placing report, `erx_dom_pci_report`, with the catalogue's
  `firmware_lost`; the hold of `pci` rows at boot;
  the SVD files and the generator's extensions for xHCI, ECAM and the
  bridge's configuration-space views; the edits these require of
  [design-system.md](design-system.md); in the backend, `ERX_IRQ_MSI`
  over the lines of QEMU `virt`'s MSI frame, returning its
  `erx_msi_message`, and the give of a PCIe function on a configured
  row; the Phase 1 manifest check accepting one `pcie` domain
  ([design-usb.md](design-usb.md#the-phase-1-part)); then the TRB ring
  form, the controller, the bus, hubs, HID into a display domain and
  mass storage into drives. It needs [1b-E](#m9-a-driver-is-an-erlang-process)
  and a display domain that reads input files; `qemu-xhci` interrupts
  by MSI-X on the frame on Fiasco as on erXos's kernel
  ([design-usb.md](design-usb.md#interrupts)).
* **(c) The BCM2711 bridge and the VL805 on the Pi 4, on Fiasco.**
  The bridge driver with the vendor's bring-up from the clean-room facts
  record, its link check, its keep-or-reset decision and its clean
  turn-off, the board probes B1 to B8, the VL805's firmware check, its
  INTx line on the Pi 4's closed bus ([design-usb.md](design-usb.md#interrupts)),
  and, once probe B1's readings are recorded, the VL805's firmware
  notification in Fiasco's root
  ([design-usb.md](design-usb.md#the-vl805s-firmware)), beside
  [1b-I](#1b-i-the-raspberry-pi-4-on-fiasco)'s board work. The
  bridge driver and the probes proceed beside (b); the controller is
  (b)'s code. The part is complete only with its dependencies in
  place: 1b-I's board boot and display, the binary form of input
  records and a display domain that reads input files, (b)'s TRB form
  and controller, and the device NIF's non-coherent DMA verified on the
  board.
* **(d) On erXos's kernel.** QEMU `virt` at
  [M9's kernel part](#m9-a-driver-is-an-erlang-process), with the
  kernel's MSI frame and the IOMMU window; the Pi 4 at
  [M12](#m12-storage-networking-boards), with the VL805's firmware
  notification as a kernel operation.
* **(e) Drives' volumes, on QEMU `virt`, on Fiasco.** The media domain
  of [design-drives.md](design-drives.md): the whole-medium window and
  drive grant, the table reader and the probe with their fuzz targets,
  the media tree with `status` and `ctl`, the finish that `eject` and
  the ordered end share, the FAT server for FAT16 and FAT32, EROFS
  through the media domain's own source, and, for development builds and
  test images, littlefs through its port once the port exists; a block
  device of the drive role. Its QEMU cases are the
  design's: a stick of each served format, on each table, listed and read
  against the harness's hashes, refused formats named, ejected and put
  back, and a stick written before an ordered `off`. It needs (b)'s
  mass storage, and the program port driver for littlefs's part.

DWC2 on QEMU `raspi4b` is not a part of the track; it is planned work
in `TODO.md` ([design-usb.md](design-usb.md#dwc2)).

Until (e), parts (b) and (c) test drives with a raw window client.

**Exit criteria, each part.** Its cores' explored tests and fuzz
targets pass their budgets, each with its seeded fault failing them;
its QEMU suite passes with its seeded fault failing it, or, for (c),
the board's checklist passes; a malformed report or status block ends
at most its function; a device unplugged in every state leaves no
slot, place or window behind; and the stack's own bounds, its queue,
block, process and backlog capacities and its per-call work, hold
under the storm cases on both phases. On Fiasco, only a case that
checks a guarantee the kernel enforces, isolation between domains, a
domain held to its budget or a neighbour's latency, reports
`unsupported`, as [design-usb.md](design-usb.md#on-fiasco)
records. For (c), the board checklist includes writing, flushing and
reading back a stick and removing it during writes.

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
as manifests in the code store, in memory
([design-live.md](design-live.md#the-code-store)); per-principal quotas on
the data partition.

**Exit criteria.** Quota and ceiling tests per limit, a session's programs
within its budget included; a user's domain at its limits leaves the
other user's latency within its budget (W5); a release-configured build's
console lines each show a login, a principal the manifest does not name
for the system shell gets none, and a lock or a log out at the UART ends
its system shell; a host-link session holds exactly its configured facets;
an overlay survives its domain's restarts and is dropped when its release
changes; each principal's hot store answers only for its own blobs; an app's `data` grant is rooted at its own
directory under `apps/`, and `purge` removes that directory
through the storage service's `remove_app`, with no user's home
reachable by it; one app name under two signers gets
two directories
([design-packaging.md](design-packaging.md#where-an-apps-files-lie)).

## Track Q: The second tier

**Goal.** What programs that cannot be changed expect of a UNIX, toward
what QNX offers: `fork`, the `exec` family, shared libraries, mappings of
files, and pseudo-terminals with process groups and sessions, on which
full-screen programs run
([design-programs.md](design-programs.md#the-second-tier)).

**Demo.** In a terminal session, toybox's `sh` runs a script with
subshells, command substitution and a pipeline; `less` pages through a
log, leaving the console as it found it; a
dynamically linked program loads a library with `dlopen`; two
programs of one session that map one file `MAP_SHARED` see each other's
stores at once, and `msync` makes them durable.

**Scope.**

* `fork` by eager copy of the program's sub-space with `erx_space_copy`,
  which only a sub-space's creator may call, charged to the session's
  budget as it goes; `liberx`'s fork with `pthread_atfork`; `vfork` as
  `fork` ([design-programs.md](design-programs.md#the-second-tier));
* the `exec` family: the session builds the new image under the
  program's anchor while the old one waits, and the program record in the
  handler keeps the program's identity, its children and its signal
  reports across images;
* shared libraries: `erx_exec` as the dynamic linker, from musl's adapted
  to map file objects, with `dlopen`, `dlsym` and `dlclose`;
* mappings of files: `MAP_PRIVATE` as copy-on-write children of sealed
  objects, and `MAP_SHARED` served by a mapper process of the session,
  one memory object per file its programs map shared, written back at
  `msync`, at every close of a mapping's open and at the last `close` of
  the file ([design-files.md](design-files.md#shared-mappings));
* pseudo-terminals that a program holds, over the session's line
  discipline, process groups and sessions, and `SIGWINCH`
  ([design-programs.md](design-programs.md#the-terminal));
* toybox's applets that need these: `sh`, `less`, `login`, `setsid`
  (toybox's `vi` is not built, since the Erlang command `vi` takes the
  name, [design-vi.md](design-vi.md));
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
mapping is gone; `less` draws on a pseudo-terminal, and the
shell's prompt works when it ends or stops.

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

## Track B: Bluetooth

**Place.** In Phase 1b, below the first two apps (Track A, "What comes
first"): parts (a) to (c) run beside every other item, since 1b-A is in
place and QEMU `virt` runs the Bluetooth domain, and part (d) runs beside
1b-I's board work. No
milestone depends on the track.

**Goal.** A phone app finds an erXos machine, connects to it and talks
to it over Bluetooth Low Energy, along
[design-bluetooth.md](design-bluetooth.md): the machine advertises its
name and its services' UUIDs, serves the GATT services apps declare in
`abi/gatt`, with Erlang processes handling them through the `ble`
facet, carries a serial line, and pairs and bonds with LE Secure
Connections so that characteristics can require an encrypted or an
authenticated link.

**Demo.** On the Raspberry Pi 4, a phone's scanner shows the machine's
name; a GATT browser on the phone lists the declared table, writes a
characteristic that an Erlang handler answers, and receives its
notifications; a terminal app for Nordic's UART service echoes through
an app; the phone pairs by typing the passkey the `pair` file shows,
the machine reboots, and the phone reads an `authenticated` value again
without pairing.

**Parts.** (a) needs nothing new below it.

* **(a) The cores, on the host.** `erx_h4`, the HCI codec and the
  bring-up core, the patch reader, L2CAP and the link core, `erx_att`,
  the table builder, the gate and the ATT server, `erx_smp` with its
  core and its cryptography against SMP's sample data, the state codec,
  `tools/gen_gatt.rb` and `abi/formats/bluetooth.txt`, with their fuzz
  targets, explored tests and seeded faults, and the codecs compared with
  Bumble's decoders on one corpus
  ([design-bluetooth.md](design-bluetooth.md#verification)).
* **(b) Stages 1 to 3 on QEMU `virt`.** The line service over
  `erx_virtio_console`, the driver of a virtio-console port, which the
  QEMU harness joins through a socket chardev to a Bumble controller;
  the Bluetooth domain in the QEMU `virt` Bluetooth suite's manifest,
  never the development manifest, with its `line` grant over that port, `abi/services/ble.txt` and
  `abi/services/line.txt`, the `ble` facet, `erx_gatt_serial`, the
  `line` grant's parameters, and the Ruby harness with the peer scripts
  of stages 1 to 3
  ([design-bluetooth.md](design-bluetooth.md#on-qemu-against-bumble)).
  It needs the domains and facets of
  [1b-A](#m5-a-wall-around-some-processes).
* **(c) Stage 4 on QEMU `virt`.** The Security Manager as responder,
  the pairing window with its pairing wait and the control tree, the store with its
  development backend, reconnection with bonds and Service Changed, and
  the stage 4 peers. The phone console joins it on the system domain's
  login facet ([design-login.md](design-login.md)), in the order of that
  document's build packages, once a passphrase checker exists.
* **(d) The Raspberry Pi 4, on Fiasco.** Board probes B-P1 to B-P6,
  `erx_pl011`'s fresh start with hardware flow control, the system
  domain's line groups for the host link and the line trees, the Pi 4's
  `line` grant,
  the controller's power notifications in the platform record over the
  firmware notification of [design-usb.md](design-usb.md), with the
  index the Bluetooth design adds, which whichever of this track and
  track U reaches the Pi 4 first brings, and the patch fetched and packed;
  after [1b-I](#1b-i-the-raspberry-pi-4-on-fiasco) and
  [M6](#m6-immutable-code-lasting-data)'s data partition, on which the
  development store keeps bonds.
* **(e) Release.** The store's release backend, the vault's state slot
  ([design-system.md](design-system.md#state-slots)), which waits for
  [M11](#m11-security-closure)'s vault, and the phone console's
  manifest opt-in, off in every shipped manifest
  ([design-bluetooth.md](design-bluetooth.md#decisions), 2),
  and the Pi 4 on erXos's kernel at
  [M12](#m12-storage-networking-boards), where the firmware notification
  is a kernel operation.

Wi-Fi provisioning, HID over GATT and classic Bluetooth are not parts
of the track ([Beyond the plan](#beyond-the-plan)).

**Testing.** `make check` runs (a)'s host tests. The QEMU suite
against Bumble runs at the landing gate when a change touches the
Bluetooth stack, the line service or `erx_virtio_console`, and at the milestone
gate; (a)'s fuzz targets run at the milestone gate's budgets. The Pi 4
runs by hand, under its checklist, once per batch.

**Exit criteria, each part.** Its cores' explored tests and fuzz
targets pass their budgets, each with its seeded fault failing them; its
QEMU suite against Bumble passes, each case with its seeded fault
failing it, or, for (d), the board's checklist passes; a malformed
packet or PDU ends at most its link, and a framing error restarts the
controller from `reset` to advertising; every refusal of
[design-bluetooth.md](design-bluetooth.md#refusals-and-error-results)
that the part brings has a test. For (c), a pairing outside a window, a
legacy pairing, a key shorter than 16 octets, a public key off the curve
and a pairing that claims a kept bond's identity each fail, a pairing
requested during the pairing wait is answered Repeated Attempts, a first
pairing reaches its level, a subscription answered before a power cut
is restored, and a bond encrypts again after the Bluetooth domain
restarts.

## M11: Security closure

**Goal.** A release build that may run untrusted code, on erXos's
kernel. 0.2 reaches the closure in its Fiasco form first
([0.2](#02-the-first-release-on-fiasco),
[design-fiasco.md](design-fiasco.md#the-security-closure)), which takes
every item below that does not name erXos's kernel.

**Demo.** A release build boots without the development banner on erXos's
kernel and asks for a login on its console; an Erlang driver runs behind
an IOMMU window; the logged-in session holds only its principal's facets.

**Scope.** A review of every residual risk in
[design.md](design.md#residual-risks); every fuzz target run at its full
budget; ASan, UBSan and TSan clean on the host builds and a UBSan kernel
through the QEMU suite; the external review; unconfined DMA refused unless
configured, device by device, and each unconfined device in a domain of
its own; the manifest check's refusal of the host link's `web` facet in a
release manifest
([design-web.md](design-web.md#the-host-tools-front-end)); hostile code in
the sub-spaces of a domain holding `SPACES`, and
a domain that churns sub-spaces
([design-kernel.md](design-kernel.md#security)); the hash check of EROFS
images: the packer's dm-verity version 1 hash tree for each image and the
root hash, salt and data-block count in each package's header, the
system partition's tree, whose image length, tree layout, salt and root
hash the boot image's manifest records and its `system_image` boot
record carries,
and the check inside `erx_verity:read/3`, the funnel M6 built, so the
reader parses only blocks that passed their image's tree (E1), with the
hash-checking reader's fuzz target
([design-storage.md](design-storage.md#invariants)); credentials for
principals: the vault in its first form, one passphrase slot per
principal and the `none` sealing backend, behind the `erx_seal` interface
that the `device` and `tpm` backends join at M12, in a domain of its own
created from the one release the boot image marks for sealing, its files
on the vault's partition served by a storage domain whose only client is
the vault, on littlefs, the stopgap until erXos's F2FS
([design-system.md](design-system.md#the-vault)); `tools/erx bench login`
on QEMU under HVF, with TCG reported apart, which sets Argon2id's
parameters against a budget of about a second; the fuzz target of the
vault's file decoder; OpenSSL 3.5 pinned and built, and the small
verifier, which the package check runs, checking update signatures
([design.md](design.md#dependencies)) once the SSH login facet's tests
calling it directly pass on it
([design-ssh.md](design-ssh.md#verification)).

**Exit criteria.** No open CRITICAL or HIGH finding; every residual risk
either fixed or recorded in `TODO.md` as accepted, with its reason. One
byte flipped in an EROFS image reads `eio`; the hash-checking reader runs
its fuzz budget clean; a release
manifest that lists the host link's `web` facet fails the manifest check;
a copy into `/apps` of a package of an untrusted signer, or one
whose header has a byte flipped, fails its `cp` with `EACCES`, and one
byte flipped in an installed package's image gives `eio` at `/app` and
under `/apps`, with the app's row `down`
([design-packaging.md](design-packaging.md#the-package)).
Release images are
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
The reference permutation's small AES implementation is selected, license
reviewed, version/hash pinned and checked against FIPS 197 vectors before
that runtime feature is enabled; source counters, image identity, exported
aliases and generation retirement have exhaustion tests. Host-link tests
exercise 128-bit session identifiers, counter exhaustion, restricted local
transport access and rejection of unauthenticated network exposure.

The hardware closure records the exact supported SMMUv3 and platform
evidence for the SMMU's own quiescence and drain at handoff, closed
initialization, ATS rejection,
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
trial boots the committed slot. The start table's reset count, cleared
by the first kept session, and the rescue configuration, which starts
no row, are built here and tested here.

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
  signing added to `ssh`; SSH's fourth stage
  ([design-ssh.md](design-ssh.md#stages)): the `{ssh_host, "ssh"}` key
  facet, the login facet's comparison of the host key and its signature
  check with the system domain's verifier, login keys and the
  credentials facet with `sshkeys`, the passphrase method, any enrolled
  principal, and release builds; the vault's partition on the boards' media; the
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
* **Boards.** The Raspberry Pi 4 Model B, whose platform record, boot
  files and Erlang drivers come from
  [1b-I](#1b-i-the-raspberry-pi-4-on-fiasco) on Fiasco, then the
  Raspberry Pi 5, whose come from
  [1b-J](#1b-j-the-raspberry-pi-5-on-fiasco), as [design-platforms.md](design-platforms.md) describes
  them: each board's
  interrupt controller, console UART, random generator, hardware watchdog
  and firmware mailbox, and the Pi 5's MSI frame, in the kernel's platform
  layer, with the kernel's device table; the hardware watchdog,
  started by the firmware from `config.txt` on a board that runs unattended
  or by the kernel under a machine lease, and reloaded from the kernel's
  timer for as long as the kernel runs, so a kernel hang resets the board
  too
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
  configuration space on a board that drives a bridge, the Pi 5, and the
  Pi 4 once [Track U](#track-u-usb) drives its BCM2711 bridge,
  to the PCIe domain alone, and
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
  ([design-platforms.md](design-platforms.md#dma)); and the board rig of
  M12 for both boards. QEMU's `raspi4b` model, under TCG, serves the
  kernel's early bring-up, booted as 1b-I's stage (a) boots it; it has no PCIe or Ethernet, and QEMU has no Pi
  5 model.

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
clean; the vault's tests against stock OTP
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

**Gate GN-board.** Repeats GN-QEMU's measurements and targets of
[1b-G](#1b-g-networking-on-qemu) natively on the Pi 4, against a Linux
peer and against Linux's stack on the same board, with the host,
compiler and flags recorded. Confirms GK3's decision whether TCP's fast
path in erXos's stack is Erlang or native code
([design.md](design.md#networking)), or reopens it with the board's
numbers.

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
the cleaner's policies and of a trial boot's read-only mount, which
replays the roll-forward records in memory and writes nothing, written
by one author from Linux's documentation and sources who implements
none of it, and the
implementation, in Erlang, from it alone; the feature bits it implements,
refusing the rest; the cleaner; the Linux oracle guest with `fsck.f2fs`;
the host tests, a reference model and workloads over every geometry
from the smallest volume to a multi-TiB sparse one, and the corpora; the
distribution guest, Linux's F2FS and f2fs-tools at scale
([design-f2fs.md](design-f2fs.md#testing-on-the-host));
the power-cut harness; the fuzz target; legal review of the clean room
before a product ships it.

**Stages, on QEMU.** Each ends in tests of its own
([design-f2fs.md](design-f2fs.md#verification)): (1) the format's
facts and the reader, `abi/formats/f2fs.txt` with the layout
language's packed storage, the codec with its fuzz targets, the
corpora's fetch, the listing, and the oracle guest making Linux
images; (2) read-only mounts, with the walk and replay in memory, of
every Linux image and corpus image, clean and with chains, each
read-only feature with chains included, erXos's
trees equal to Linux's; (3) the format and read-write mounts with
checkpoints, every namespace and data operation, the room rule, the
mount checkpoint with its copies, orphans, the test window, the model and the
generator over every geometry, and the distribution guest, every
image passing `fsck.f2fs` and listing equal in Linux; (4) `fsync`
records and the power-cut harness, every crash state checked in erXos
and in the guests, and the probes; (5) the cleaner, under churn to
high utilisation at every format size; (6) parity and the switch, the
file-semantics corpus and pjdfstest against littlefs and Linux, gate
G13, then the seam's change and littlefs's deletion. The estimate is
about 8,000 lines of Erlang, 2,000 of Ruby and 5,000 of tests.

**Scope, with M12, after 0.2.** The installation that brings erXos's
F2FS to the boards, which creates the data partition and the vault's
partition afresh, with nothing littlefs wrote carried across, and the
update service's refusal of an update whose storage formats differ from
the running system's ([design-storage.md](design-storage.md#system-updates)).
Both follow 0.2, which ships littlefs on the boards.

**Exit criteria, on QEMU (1b-H).** Every image erXos's F2FS writes, and
every state of the power-cut harness, passes `fsck.f2fs` and mounts in the
Linux guest at the last completed checkpoint with every acknowledged
`fsync`; a read-only mount writes nothing, over a window that fails every
write, and Linux's `ro,norecovery` mount of each erXos image shows its
last checkpoint without the records; the file-semantics corpus
agrees with littlefs and with Linux's F2FS, every difference a bug fixed,
a documented improvement with a test, or a bug in littlefs recorded as
such; the fuzz target runs its budget clean; the host runs and the
distribution guest's batch run their milestone budgets clean, every
corpus image meets its verdict, and every difference between kernels is
reported with both named.

**Exit criteria, with M12.** The partition after a failed trial is byte
for byte the partition before it; the installation and the update
service's refusal have their tests on the Pi 4; and M11's closure holds
over what M12 adds, as the ground rules require.

**Gate G13.** Measures erXos's F2FS against littlefs over the
file-semantics corpus and against Linux's F2FS in the oracle guest, the
power-cut harness's results, and throughput, commit latency and the
cleaner's overhead, on QEMU in 1b-H. It decides the replacement of
littlefs there on the corpus, the oracle guest and the power cuts alone,
for a release after 0.2: 0.2 ships littlefs whatever G13 decides.
Its throughput, commit latency and cleaner numbers on Fiasco, whose
block path pays a service round trip per interrupt and acknowledgement,
are a baseline recorded with Fiasco named; the Pi 4's SD card
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
TCP stack translated into Erlang at the releases that design pins, its
processes and packet path, grants and sockets, and its verification.
TCP's fast path in native code, behind the same process interface, only
if GK3 decides so on erXos's kernel. The work comes in two stages, the
design's core and then its extensions
([Scope](design-network-stack.md#scope)):

* **First stage, the core**: the link, IPv4 and IPv6 layers, UDP and TCP
  with the design's defaults, the grant, `gen_tcp`, `gen_udp` and `inet`
  through the `erx` socket backend, the POSIX socket protocol, the
  resolver, the port mapper, distribution to other machines, over TLS
  alone in release builds, the decoders' fuzz targets, the two
  packet-script runners against a FreeBSD 15.1 guest, and the traffic
  tests against the FreeBSD guest and Linux's stack. In this stage
  redirects are ignored, the multicast options answer `{error, enotsup}`
  and `socket:open` answers `{error, enotsup}`, each a documented
  difference with a test, with OTP's socket suites expected failures,
  since `ssl`, `ssh` and distribution use `gen_tcp`.
* **Second stage, the extensions**: the `socket` and `net` modules and
  OTP's socket suites, raw ICMP sockets for `ping`, and the rest of the
  design's extensions.

Outside M14, later, behind the stack's seams: RACK-TLP as a loss module,
deferred, with the default stack as the
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
the stack and the numbers, taken on Fiasco, are a baseline; and on
both boards at M12, on erXos's kernel, which confirm the acceptance with
their numbers.

## Decision gates

| Gate | Milestone | Measures or asks | Decides |
| --- | --- | --- | --- |
| G0 | M0 | the Fiasco set's license scan and link closure; `lld` installed | what enters the tree, and the GPL-headed files Fiasco keeps |
| G3 | M3 | W1 against stock OTP under HVF; footprint; boot time to the shell | the baseline |
| GK1 | before Phase 1 is complete, beside Phase 1b | the pilot's time and defect rate | the pace of the rest of track K and of the plan |
| GF | track F, after 0.2 and stages F1 to F7 | the downsides left after track F, each classed as closable on Fiasco, with its cost there, or as needing erXos's kernel; that cost against erXos's kernel's remaining estimate, recalibrated by GK1; F7's root pager and root-thread measurements under track Q's first consumer; whether group quotas fitted as a scheduler variant; the fuzz campaign's and the upstream watch's findings since 0.2; whether anything must claim FD24's construction properties | whether erXos builds its own kernel (GK2 and Phase 2) or stays on Fiasco with the rows only erXos's kernel closes published as downsides ([Track F](#track-f-fiasco-improved-to-the-decision)) |
| GK2 | after the pilot, 1b-A and GF choosing erXos's kernel | Phase 1's and 1b-A's tests and benchmarks baselined on Fiasco, the conformance roster written from the design | the start of erXos's kernel in full |
| GK3 | M7 | the conformance suite, Phase 1 and 1b's transcript tests, the oracle and the benchmarks on both kernels; G5's E-D3, E-D4 and full E-S2; G9's latency and throughput and GN-QEMU's packet-path measurements repeated on erXos's kernel | the replacement of Fiasco; G5's provisional decisions confirmed or revised, the death path's batching and `system_queue`, and no kernel object per lightweight process; whether a program's start needs a cheaper path; whether TCP's fast path in erXos's stack needs native code |
| G2 | M2 | early E-S2 (kernel thread switch, IPC round trip through a gate, park and wake); E-S4 FIFO wake latency; E-S10 | whether the two-level model stands on erXos's kernel; NIFs that move to dirty schedulers |
| G5 | 1b-A, provisionally; confirmed at GK3 | on Fiasco: E-D1 and E-D2 (`tools/erx bench xdomain-pingpong`, `xdomain-throughput`); BeamAsm's speedup and footprint in an ordinary domain; translation time at a domain's start. At GK3: E-D3 and E-D4 (`xdomain-stall`, `domain-lifecycle`) and full E-S2 | provisionally: the runtimes' and the domain service's default table sizes, `cap_limit` among them; `lane` and the manifest's `system_lane`, the producer's wait rule, encoding straight into the lane; the funnel's allowance per step; the busy limit and the facets' limits; the ahead-of-time roster's triggers. At GK3: the manifest's `system_queue` and the death path's batching; no kernel object per lightweight process; the rest confirmed or revised |
| GP | track P | a program's start (`tools/erx bench spawn`) against its budget and `posix_spawn` on Linux; the `make`-shaped workload and `tools/erx bench pipe`, hosted and under HVF, Fiasco's numbers provisional | the channel's and data area's defaults; the handler's batching; one ring per write end (whether a program's start needs a cheaper path is GK3's) |
| G6 baseline | the end of 1b-D, on Fiasco | an idle domain's memory by kind, a session's and a program's, the session services' floor and a facet's heap; E-D1 and E-D2; `tools/erx bench fs` and `blk` against M6's baseline | nothing; it records the baseline G6 compares against |
| G6 | after M5's and M9's kernel parts | the system on erXos's kernel: an idle domain's memory by kind, a session's and a program's, the session services' floor and a facet's heap; E-D1 and E-D2; a program's start; isolation beside hostile domains; the EROFS reader's, littlefs's and the block driver's throughput and commit latency on QEMU (`tools/erx bench fs`, `blk`) against M6's baseline and the G6 baseline | whether the system meets the design's budgets before M8 and M10 build on it; G5's lane defaults and the facets' limits confirmed or revised |
| GW | track D's part 1, in 1b-C | a record view's round trip over the host tool's front end for the machine's record and a 1,000-child listing, under HVF and over a host link paced to a 115,200-baud UART's rate, a stand-in that a board's UART replaces at M12 | whether whole records stay on the wire or the web protocol gains a record difference: whole records stay, since an update of the listing crosses the paced link in about 1.1 s, so a view of a changing listing still refreshes about once a second |
| GD | track D's part 5, on its panel, once part 7 has run the Erlang renderer | the Erlang renderer's frame time on a 240 by 240 panel against LVGL's on the same panel; the parity test through both; part 7's Erlang renderer may record a QEMU frame time as a preview before the panel exists, deciding nothing | whether LVGL leaves the panels |
| G8 | M8 | E-S1 (the ladder C0 to C2), E-S3 to E-S9 | default cooperation features; time slice, grace and period; capacity rules; the shared services' sizing rule and whether a service needs a child group per client class |
| G9 | M9: recorded in 1b-E, decided at its kernel part | interrupt-to-handler latency per device class (`tools/erx bench irq`), ring throughput against sDDF's figures, `tools/erx bench blk`, the network driver's packet rate, MSIs under HVF; Fiasco's numbers recorded with Fiasco named | at the kernel part only: completion batching per device class; virtio-pci over virtio-mmio; each row of the driver table, which alone admits a native shim; no row from Fiasco's numbers |
| GQ | track Q | `fork` of 10, 100 and 1,000 MiB against Linux in a guest; a dynamically linked program's start against a static one's; the fill and the write-back cost of the session's shared mappings, files of 64 KiB to 1 GiB, with `tools/erx bench mmap`, against descriptor reads and writes; on CPUs with hardware dirty-bit management, the fold of dirty bits into the object's stored marks at `munmap` and `exec` over large shared mappings, with `tools/erx bench mmap` | whether `fork` grows a copy-on-write path; whether the shared mappings' fill and write-back points meet the corpus |
| G12 | M12 | throughput and commit latency on the Pi 4's SD card, against G6's on QEMU; boot time to the shell and to the first pet on both boards; the trial path's timings; slot images' sizes | the default trial deadline; the watchdog's boot deadline per board; whether images need compression |
| GN-QEMU | 1b-G, on Fiasco | the packet-path prototype's UDP echo and TCP bulk transfer on QEMU under HVF, against a Linux peer and line rate, recorded with Fiasco named | nothing; it records the baseline GK3 repeats on erXos's kernel |
| GR | 1b-I, before the first board boot | the boot probe on the Pi 4 under Fiasco; the board is a 4 GB Pi 4 and the board pass is manual | the RAM the Pi 4's platform record names |
| GR5 | 1b-J, before the first board boot | the boot probe on the Pi 5 under Fiasco; the board is a 4 GB Pi 5 and the board pass is manual | the RAM the Pi 5's platform record names; whether the Pi 4's `bootstrap` build serves it |
| GN-board | M12 | the same on the Pi 4, against Linux's stack on the board and line rate | GK3's decision on TCP's fast path confirmed or reopened |
| G13 | M13: 1b-H on QEMU, the Pi 4 at M12 | erXos's F2FS against littlefs over the file-semantics corpus and against Linux's F2FS and `fsck.f2fs`; the power-cut harness; throughput, commit latency and the cleaner's overhead, on Fiasco a baseline; the Pi 4's SD card at M12 | the replacement of littlefs, on QEMU, from the corpus, the oracle guest and the power cuts; the Pi 4's numbers may reopen it |
| G14 | M14: 1b-G on QEMU, the boards at M12 | erXos's stack against FreeBSD's over the network test corpus and the packet scripts; throughput, latency and memory on QEMU, a baseline on Fiasco, and on both boards | the acceptance of erXos's stack, on QEMU; the boards confirm it |

A numbered gate takes its milestone's number: M7's gate is GK3, G6's
baseline ends track P's first part and G6 follows the kernel parts of M5
and M9, GN-QEMU belongs to 1b-G and GN-board to M12, and M1, M4, M6, 0.1,
M10 and M11 have none. The research
records are point-in-time reports and
use the gate names of the plan they were written against. The gates that
[research-baselines.md](research-baselines.md) names map here as follows:
its G2 to track K's first measurements (latency, measured there as
interrupt latency and here as deadline-to-resume latency), its G0 to M0
(repeating the ERTS
baselines with OTP 29.1.2), its G4 and G5 to G3 and G5 (the measurements
on erXos), and its G6 to G6 (the restricted decoder's cost under the
interpreter, within a frame's cost across a connection).

## Stopgaps and Fiasco

| Component | Seam | Replaced at |
| --- | --- | --- |
| Fiasco near-stock, with `bootstrap` and `sigma0` | the kernel interface: `abi/erx_abi.txt` and `liberx`'s backends; in Phase 1 the Fiasco backend over Fiasco's own calls, the system domain's `liberx` owning every kernel object; in Phase 1b also lanes, sub-spaces, doorbells and device holders as rows of its root service | M7, if gate GF chooses erXos's kernel |
| Fiasco's fixed priorities with no quota, grant or group enforcement | the scheduler core, `erx_group_configure` recording its grant | group quotas in track F's F5 if they fit; otherwise, or for what they leave, M7 (the scheduler) and M2 (groups and quotas) |
| The Phase 1 manifest check and root startup rule | the packer's `Admitted` value and the manifest's properties | track K (`erx_root_plan`); M5, M9 and M11 (the properties, as [design-fiasco.md](design-fiasco.md#the-phase-1-manifest-check) lists them) |
| Virtio-mmio devices with ordinary interrupts and unconfined DMA, driven by the same Erlang drivers | DMA profiles; IRQ objects; the device NIF | M9's kernel part (virtio-pci with MSIs and the IOMMU), M11 (refused unless configured) |
| A host link holding every facet but the system-shell facet | session facet tables | M10, M11 |
| littlefs, the read-write file system of the data partition and the vault's partition, a NIF in the system domain at M6, in the storage domain from 1b-E, and a sub-space port of the storage domain once track S's port driver exists | `erx_fs`, the storage service's file interface, and the port's channel | M13, by erXos's F2FS, in Erlang, at G13, decided on QEMU in 1b-H, through an installation that creates both partitions afresh, which comes to the boards with M12, after 0.2 |
| LVGL, the widget renderer on panels, a native program of the application's session | the renderer behaviour `erx_ui_renderer` and the generated reader of `ui.txt`'s operations | by the Erlang renderer, when GD admits it; GD is first measured on track D's part 5 panel |

Fiasco carries the rows of the backend's table in
[design-fiasco.md](design-fiasco.md#the-call-table), each in full, with
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
           1b-A domains on Fiasco
             --> session domain (1b-B's first slice) --> 1b-C track D part 1 (GW) --> part 2
             --> session domain and its terminal relay --> evi (track S)
             --> 1b-E M9 on Fiasco --> track A part 3, installing at run time (on 1b-E's storage domain)
           track A part 1, the start table (on the session domain and M6's data partition)
             --> track A part 2, packages added to an image (the SDK, the apps row, erx_app, examples/)
             --> 1b-G network domain, GN-QEMU, M14 on QEMU
           1b-G's driver and stack in the system domain (from Phase 1, beside 1b-A)
             --> 1b-C track D part 3, the window stack on QEMU
             --> 1b-D track P's first part --> G6 baseline --> toybox's applets (the rest of 1b-B)
             --> 1b-C track D part 4, the QEMU kiosk (on 1b-D's first slice, with 1b-B's sub-space ports and pipes, and track A's part 2)
             --> 1b-F track D part 6 --> part 7 --> part 8, desktop programs
           1b-H M13 on QEMU (any time; lowest priority)
           1b-I the Pi 4: (a) serial shell on raspi4b after Phase 1, then once on the board (GR)
             --> (b) storage after 1b-E, (c) network after 1b-G, (d) display after 1b-C part 3,
                 (e) the header after 1b-E
           1b-J the Pi 5: (a) headless boot, (b) serial shell and probe (GR5)
             --> (d) bridge and MIP after 1b-E --> (e) RP1 --> (f) Ethernet after 1b-G, (h) USB after track U (a);
                 (c) storage, (g) display after (b)

0.1:       published (see 0.1)

0.2:       0.1, Phase 1b and track A --> the backend on Fiasco's mechanisms, the release's Fiasco build, the closure on Fiasco
             --> the release images, the soak and the Pi's manual passes

Track F:   0.2 --> F1 handles, F2 mappings, F3 threads, F4 hardening, in parallel
             --> F5 Fiasco's scheduler stages: status words --> deferred preemption --> group park --> group quotas
             --> F6 budgets with caps, F7 a pager in the root under track Q's first consumer
             --> GF, Fiasco or erXos's kernel

Track K:   pilot (GK1), beside Phase 1b, continuing whatever GF decides
             --> kernel in full (GK2), after 1b-A and GF choosing it --> M7 (GK3, parity over 0.2)

Phase 2:   (if GF chooses erXos's kernel) M7 --> M2 --> M5's and M9's kernel parts --> G6 --> M8 --> M10 --> M11 --> M12 (boards; M13, M14 and GN-board there)
           rest of track P --> track Q (after M7)
           track D: part 5, kiosks on boards (after part 4 and M12); part 9, the web on the network (after part 2, M10, M11 and 1b-G)
```

* The order within each phase is [the overview's](#overview). Track K's
  pilot runs beside Phase 1b, since its cores are host-built C17 with no
  shared seam and its calibration is needed whatever the order; the kernel
  in full waits for gate GF, and starts after 1b-A, so its conformance roster covers the rows
  1b-A's consumers use and each refusal of the backend names what M7 must
  add. Nothing in Phase 1b changes the kernel interface, only which rows
  Fiasco carries.
* 0.1 is published ([0.1](#01-the-preview)), and 0.2's items come
  first ([0.2](#02-the-first-release-on-fiasco)). Within Phase 1b the
  two basic packaged apps, the offline kiosk and Doom on the virtio
  keyboard, lead, with track A's second part under them; their full
  milestones follow; every other item fills the remaining workers
  ([Track A](#track-a-apps), "What comes first").
  Track U runs below
  them: its part (a) beside everything, its part (b) after 1b-E, its
  part (c) beside 1b-I's board work. Track B runs beside track U: its
  parts (a) to (c) beside everything, its part (d) beside 1b-I's board
  work, with WiFi, 1b-I's part (f).
* Track D runs beside the critical paths from the session domain on; no
  milestone needs it. Its first part, the browser over the host link,
  needs no device and comes first; the window stack follows, then the
  kiosk and the desktop, which are both its clients, and its
  later parts wait for the milestones that bring their programs, boards,
  logins and network.
* Host-buildable code (the C17 cores, the funnel and the lane reader, the
  domain library's plans, the device NIF's envelope, the pipe core,
  `erx_etf`, the draw core and codec, `erx_memdraw`, the terminal state
  machine, the widget tree's schema and difference, the web protocol's
  codecs) and its fuzz targets are written and tested on the host
  ahead of the milestone that integrates it.

## Beyond the plan

| Item | Why it waits | Decided |
| --- | --- | --- |
| An awklog form of the manifest check | it would express the manifest's relational rules (ownership, facet targets, boot order, rescue closure) as Datalog in place of Ruby, if that is simpler; nothing needs it, and awklog needs approval | after Phase 1, with approval of awklog, once M5 gives the manifest its rules for domains |
| Ahead-of-time translation of Erlang code | the JIT in each ordinary domain is the design; the roster keeps the triggers | on a trigger of [the options](design-runtime.md#running-erlang-code-the-options) |
| Landing pads in BeamAsm's generated code | hardening for generated code in ordinary domains | with M11's review, or on a board with branch-target protection |
| Direct dispatch of lightweight processes across domains, in the style of L4Re's vCPUs | an optimisation the proposal makes optional | only if E-D1 and E-S2 show the funnel's copy and the doorbell dominate |
| A weighted fair queue within a level | round robin with quotas and capacity meets the requirements | if E-S1 and E-S9 say otherwise ([design-scheduler.md](design-scheduler.md#risks-and-open-questions)) |
| A child group per client class inside a shared service | one capped grant per service, scheduled fairly by the service, is the design | if E-S8 shows one service's flooder starves an urgent client past the sizing rule's headroom |
| Other runtimes (Go, Lisp, nested runtimes) | "native for now"; the contract leaves room | when a use appears |
| A shell compatible with tcsh | the first version speaks rc's language | likely the command shell's next version |
| `system` and `popen` through a POSIX `sh` | they run `rc`; track Q brings toybox's `sh`, over `fork` ([design-programs.md](design-programs.md#the-posix-lite-personality)) | the user's, once track Q has brought `sh` |
| vi-style line editing in the command shell | emacs-style editing first | possible later |
| The network as files, `/net` | the network service's own interface comes first | with the network service's design |
| A copy-on-write `fork` | the eager copy is the first `fork`, and copy-on-write is an optimisation | at gate GQ |
| A separate native root task that keeps configured domains alive across a restart of the system runtime | the system domain is the root task and its fault is a reset; the domain library behind one C interface keeps this a change behind a seam ([design.md](design.md#alternatives-considered)) | only if measured availability of the system domain asks for it |
| Hosting a sub-space under a user-level kernel, through vCPU user mode | Fiasco's vCPU interface can run a sub-space's code on a thread of its creator, as L4Linux does; erXos's subset leaves that mode out | when a use appears |
| An MSI translation service in the interrupt controller | QEMU `virt`'s MSI frame serves both accelerators ([design-platforms.md](design-platforms.md#msi-frames)) | with a board that needs it |
| Unmapping the kernel from user-mode page tables | needed only on cores that Arm lists as affected by rogue data cache loads | with each board port, from Arm's list of affected cores |
| The release process: who keeps the release signing key and how it is replaced; whether release builds offer a host link | no release build exists yet | when erXos makes release builds |
| Audio | not needed for the thesis | not planned |
| GPU acceleration | the desktop and the kiosks run on software rendering first; OpenGL-class rendering needs research and a design of its own | planned, [Track D](#track-d-windows-widgets-and-the-web) part 10 |
| USB | not needed for the thesis; wanted for keyboards, pointers and USB sticks on QEMU and the Raspberry Pi 4 | [Track U](#track-u-usb), in Phase 1b below the first two apps |
| Bluetooth's later stages: Wi-Fi provisioning from a phone, HID over GATT, classic Bluetooth | track B's first consumer is a phone talking to a peripheral; provisioning needs 1b-I's WiFi, part (f), and HID over GATT the central role and the USB design's HID cores ([design-bluetooth.md](design-bluetooth.md#later-stages)) | in that order, each when its consumer is named |
| x86-64 | out of scope | not planned |
