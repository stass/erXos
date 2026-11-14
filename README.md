<p align="center">
  <img src="erxos-logo.svg" alt="erXos" width="480">
</p>

# erXos

What if every Erlang process were an operating-system process?

erXos is an operating system built on that idea. A small capability
microkernel sits underneath. Above it runs one Erlang system that spans
the whole machine. Drivers, file systems and system services are Erlang
processes, supervised like any other: when one crashes, its supervisor
restarts it. You can inspect, trace and change the running machine from
an Erlang shell, all the way down to kernel objects. And to the people
using it, it feels like UNIX.

> In erXos, Erlang's process is the operating system's process: one
> process space, one message system and one view of identity, supervision
> and inspection span every runtime.

The [architecture](docs/design.md), the [roadmap](docs/plan.md) and the
[working agreement](CLAUDE.md) define the project.

## Goals

* **Secure by construction.** Authority is a capability someone handed
  you. Knowing a pid, a path or a node name grants nothing. The
  guarantees hold because the code cannot express the alternative, not
  because every caller remembered a rule.
* **Millions of processes.** Erlang processes are cheap to create and
  cheap to switch. erXos keeps them cheap. Each runtime schedules its own
  processes without entering the kernel.
* **Crashes are routine.** A file system meets a corrupt block. A driver
  wedges its device. The widget renderer dies. Each fails alone, its
  supervisor restarts it, and the rest of the machine carries on.
* **Erlang wherever practical.** Erlang runs the drivers, the file
  systems, the network stack, the shell and the services. C is for the
  kernel, the thin layer under the runtimes, device shims, and per-byte
  work such as checksums and hashing.
* **A live machine.** Recompile a module on your laptop, and a second
  later it runs on the target. Upgrade a driver in place. Follow any
  process to the line of source it is executing.
* **UNIX look and feel.** The shell, files, pipes, `ps`, `grep` and
  terminals behave as a UNIX user expects, as on QNX and Plan 9. A
  POSIX-lite layer runs FreeBSD programs recompiled from source.
* **One kernel, many runtimes.** The kernel hands out CPU time to
  runtimes and native threads alike. ERTS comes first. C programs share
  the machine on the same terms.
* **Simple by design.** A few concepts, used everywhere. The build
  enforces the rules, not the reviewer. Where a declarative description
  is simpler than code, it replaces the code.
* **Cross-platform.** AArch64 comes first, on QEMU `virt` and the
  Raspberry Pi 4; the Raspberry Pi 5 follows. Other architectures are ports, not redesigns.

## Architecture

erXos stands on the shoulders of giants, and adds what none of them had.
From *Erlang/OTP* it takes processes and supervision; from *L4* and *Fiasco*,
the kernel. *EROS* and *Genode* taught it to account for resources; *Plan 9*
and *Inferno*, namespaces, files, the shell and graphics. *QNX* showed how
UNIX can sit on a microkernel, *Genera* how a whole machine can stay open
to inspection, and *Psyche*, *Barrelfish* and *Akaros* how a kernel and a
runtime can share the CPUs.

What is new is how the pieces meet. The Erlang process becomes the
system's process, across address spaces, with Erlang's semantics
intact. Every value the inspector shows says who reported it and
whether it is known. The command shell feels like FreeBSD's, `ps | grep`
included, though its commands are Erlang; one `erl` away, the same
processes are live values to link to, trace or open at their source
line. And a
browser is simply another display: it receives the same widget commands
as a screen and renders them in its own medium, rather than mirroring
pixels. The [overview](docs/overview.md) tells the longer story.

* **A capability microkernel.** The kernel knows threads, memory,
  capabilities and interrupts. It knows nothing of Erlang. Everything
  else runs in user mode, the runtimes included. erXos's own kernel
  follows *L4* and *Fiasco*, with lessons from *seL4* and *Zircon*. Until it is
  written, a near-stock Fiasco stands in behind the same interface.
  ([kernel](docs/design-kernel.md), [stopgap](docs/design-stopgap.md))
* **Two-level scheduling, one CPU authority.** The kernel grants CPU time
  to groups of threads. Each runtime schedules its processes on the
  threads its group pays for, without a kernel call. The kernel enforces
  every grant and never calls back into a runtime's scheduler. *Psyche*,
  *Akaros* and *Barrelfish* showed the way; *scheduler activations*, long
  abandoned, showed what to avoid.
  ([scheduler](docs/design-scheduler.md))
* **Domains: a wall around some processes.** A domain is an address
  space with its own runtime. It is also an Erlang node. Processes in
  different domains link, monitor and message each other as Erlang
  processes always have. But a domain reaches another's process only if
  that process's runtime exported it, so a forged pid reaches nothing.
  A crashed domain looks like a dead node. Think of Erlang distribution
  inside one machine, with *Safe Erlang*'s pids as capabilities.
  ([domains](docs/design-domains.md))
* **A budget for everything.** Every kernel allocation is charged to a
  budget carved from its parent's. Delete the budget, and everything
  charged to it goes too, so ending a domain is one operation. Users get
  memory quotas and a CPU share without a container runtime. *EROS*'s
  space banks are the model, with *Genode*'s quotas.
  ([budgets](docs/design-kernel.md#budgets),
  [resource policy](docs/design-system.md#resource-policy))
* **Private namespaces, one file protocol.** This comes straight from
  *Plan 9*. Each domain sees files through its own table of file servers.
  There is no global root, so a path is the visible face of a
  capability. Every file server, from storage to `/proc` and `/dev`,
  speaks 9P2000.L. ([files](docs/design-files.md),
  [`/tmp`](docs/design-tmp.md))
* **Drivers are Erlang processes.** A driver is a supervised process over
  a thin device shim. Kill the network driver mid-transfer. Its
  supervisor resets the device and restarts it, and the shell never
  notices. *HydrOS* and *Midori* took the same view.
  ([drivers](docs/design-system.md#drivers),
  [device shim](docs/design-runtime.md#the-device-nif))
* **Storage in Erlang.** Releases ship as read-only EROFS images, checked
  block by block. Data lives in F2FS, removable media in FAT. An update
  goes to a spare slot and commits only after a healthy trial boot. A
  bug in a file system crashes a process, not the machine.
  ([storage](docs/design-storage.md))
* **The live machine.** This is *Genera*'s legacy. One inspector shows
  CPUs, kernel objects, domains, budgets and processes as live records,
  and tags each value with who reported it. Tracing follows processes,
  messages between domains and kernel events. Code loads hot from the
  shell or from your laptop. ([live machine](docs/design-live.md))
* **Windows are files.** A display serves each window as a directory of
  files, as *Plan 9*'s *rio* does. A program finds its window at
  `/dev/draw` and draws with *Plan 9*'s draw protocol. A terminal is a
  window too, and keeps shell output linked to the values behind it, as
  *Genera*'s dynamic windows did. The same window system runs a desktop
  of overlapping windows, or a kiosk, a dashboard or a pair of smart
  glasses with one full-screen window. ([display](docs/design-display.md))
* **One interface, every medium.** An Erlang application never draws. It
  describes its interface as a term: a tree that says what the widgets
  are, what they hold and which events they raise. When its state
  changes, it sends the new tree, and events come back as messages. It
  holds no widget handles and issues no widget commands.
  ([widgets](docs/design-display.md#widget-trees))
* **Same stream, different medium.** Every display gets the same stream
  of widget changes and sends back the same events. Each renders it in
  its own idiom: a screen as pixels, a panel as *LVGL* widgets, a browser
  as a web page. Nothing is mirrored. One application, unchanged, looks
  native on a touch panel and in a browser tab.
  ([web](docs/design-web.md))
* **UNIX on the surface.** As on *QNX* and *Plan 9*, UNIX is how the system
  looks, not what it is built on. The command shell speaks rc's language
  and pipes text between commands, as UNIX does. Toybox supplies the
  familiar tools. Native programs run on a POSIX-lite layer over musl,
  each holding only what its starter handed it.
  ([shell](docs/design-shell.md), [programs](docs/design-programs.md),
  [pipes](docs/design-pipes.md))
* **Declarative where it is simpler.** One system manifest says what the
  machine runs. The build checks it and packs it into the boot image, an
  idea taken from *Barrelfish* and the *BOOM* project. The kernel ABI and the
  hardware registers each have one source, and every header and accessor
  is generated from it. ([manifest](docs/design-system.md#the-manifest),
  [ABI](docs/design-abi.md), [generation](docs/design-generation.md))
* **Checked by the build.** Decisions are pure functions; effects stay at
  the edge. Every "only X may do Y" rule is a build check, with a test
  that proves it catches a violation. TLA+ models check the protocols.
  Every parser of untrusted input has a fuzz target. And OTP's own test
  suites hold erXos's Erlang to stock OTP's behaviour.
  ([verification](docs/design-verification.md),
  [host oracle](docs/design-host-oracle.md), [style](docs/style.md))

## Current status

erXos is in Phase 1 of the [roadmap](docs/plan.md): the system is up on the
stopgap Fiasco kernel, and Phase 1b moves the user-facing parts into
domains of their own. Every build is a development build and prints
`development build: trusted code only`. `tools/erx boot` builds an image
and boots it in QEMU to the command shell:

```
development build: trusted code only
erx: erts: erl_start runs, 40 arguments
Erlang/OTP 29 [erts-17.1.1] [source] [64-bit] [smp:1:1] [ds:1:1:10] [async-threads:1]

rc: the command shell; erl starts the Erlang shell
% echo hello from erXos > /tmp/hi
% cat /tmp/hi
hello from erXos
% erl
Eshell V17.1.1 (type help(). for help)
1>
```

**Platforms**

* QEMU `virt` (AArch64) boots to the command shell on 1 to 8 CPUs, under
  HVF and TCG.
* The Raspberry Pi 4 boots on QEMU's `raspi4b` model (TCG only) and on a
  real 4 GB board from an SD card that `make pack PLATFORM=raspi4b`
  builds. On the board the serial console, the SD card (`/data` survives a
  power cycle) and Ethernet (1000 Mb/s, DHCP, `ping`, `host`) work; the
  card's [manual checklist](docs/design-platforms.md#the-sd-card-and-ethernet-on-a-board)
  and the [first pass](docs/research-rpi4-board-pass.md) record what was
  tried. The board needs a bootloader dated 2022-12-01 or later.
* Boot images are reproducible, for the QEMU disk image and the Pi 4's
  SD card alike.

**Kernel and domains**

* ERTS runs in user mode as the system domain on the stopgap Fiasco, behind
  `liberx`; OTP 29.1.2 and musl live in the tree, modified.
* Domains each run their own ERTS (interpreter or BeamAsm) in an address
  space of their own. The domain service starts the manifest's domains
  and creates others on request; domains message each other as Erlang
  nodes do.
* erXos's own kernel has begun as host-built C17 cores (object store,
  capability table, budgets, page funnel). None of it boots yet.

**Erlang runtime and tools**

* The Erlang shell, `erx:i()`, `source(Pid)`, `erx:trace/1` and `/proc`
  show processes and kernel objects; a value the stopgap cannot measure
  reads as unsupported or partial.
* A host link lets `tools/erx load`, `watch` and `files` replace modules in
  the running system and read its files; `tools/erx web` shows the
  machine's records in a browser.
* Hosted mode runs the runtime as a macOS process for fast iteration.

**Shell and commands**

* The console's shell is rc, written in Erlang, with job control. Its
  commands (`ls`, `cat`, `grep`, `ps`, `top`, `mount`, `dmesg`, `uname`,
  `ping`, `host` and others) are Erlang commands that follow FreeBSD's
  output, and pipes carry text.
* The start table runs services; `service` enables and stops them as
  FreeBSD's does.
* Programs have pipes and a session process can start one. The shell does
  not start programs yet.

**Files and storage**

* Per-domain namespaces, file servers across domains and `/tmp` on a RAM
  file system in Erlang.
* A storage domain serves `/data` from littlefs over a virtio block driver
  on QEMU and an SD driver on the Pi 4, and restarts cleanly after a
  failure. An EROFS reader mounts read-only images.

**Networking**

* The network stack is `erx_net`, an Erlang redesign of FreeBSD's:
  Ethernet, ARP, IPv4, IPv6 neighbour discovery, ICMP, UDP, TCP and DHCP.
  It runs in a network domain over the virtio-net driver on QEMU and the
  GENET driver on the Pi 4. `ifconfig`, `ping`, `host`, and `gen_tcp`
  connections out and in work in root's session.

**Display and input**

* A window server serves windows as files; clients draw into window buffers
  with `erx_win`, and the virtio-gpu, virtio-input (keyboard and tablet)
  and Pi firmware-framebuffer drivers are Erlang processes. A QEMU suite
  compares screenshots; the Pi's screen is checked by hand.

**Web demo and checks**

* The website runs a demo in the browser on an AArch64 emulator, with a
  menu of hardware faults, and offers the Pi 4 card and a QEMU image for
  download.
* The checks are described under [Correctness and testing](#correctness-and-testing).

**Not built yet**

* The rest of erXos's own kernel, programs started from the shell and
  the musl seam for C programs' pipes, the rest of the browser client, and
  the POSIX-lite layer. Each has a design document in [docs/](docs/).

## Correctness and testing

erXos checks its code against answers that do not come from the code
itself: stock OTP, musl's own tests, a model checker, a weak-memory
simulator and seeded defects. A check says what it covered and nothing
beyond that. Most of the commands are described under
[Fetch, bootstrap and check](#fetch-bootstrap-and-check), and
[docs/design-verification.md](docs/design-verification.md) holds the rules
for what counts as evidence.

* **Stock OTP is the oracle** (`make check-oracle`). OTP 29.1.2's emulator,
  kernel, stdlib and compiler test suites run on erXos and on stock OTP on
  the development host, and the results are compared case by case. Every
  difference must be listed with its cause in a table of known differences:
  a difference the design states, a case that cannot run yet, a bug
  `TODO.md` names, or an upstream bug. Any other difference, or a listed
  one that no longer occurs, fails the gate. The same gate runs musl's
  `libc-test` against erXos's C library.
* **Weak memory under herd7** (`make check-litmus`). herd7 simulates how a
  processor may reorder memory accesses. The litmus tests (small
  programs with a stated bad outcome) in `test/litmus/` cover the lane's
  wake handshake and ring positions and the pipe's lock, under Arm's AArch64 memory model and,
  for the C11 form, RC11 (the repaired C11 model). Each protocol with its
  fences or acquire loads must never reach the bad outcome. Its twin
  without them must reach it, or the test would pass whatever the fences
  did.
* **TLA+ models under TLC** (`make check-tla`). TLC explores every state
  of a bounded model. Three protocol models check the lane (no record
  overwritten before it is read, records read whole, no lost wake),
  connections (a connection's end handled after every frame it
  published, a name reused only after the earlier connection went down)
  and links (an answer about a process arrives after everything the
  process sent, and a link two processes make towards each other is
  never left with one half). Each model has seeded defects, such as a
  dropped fence or an answer sent early, that must fail on the property
  or the deadlock check they name. The models for the
  host link's sessions, the update protocol and the scheduler's
  cross-CPU protocol are planned and not written.
* **CBMC, a bounded model checker for C** (`make check-cbmc`). The
  harnesses in `test/cbmc/` check the budget arithmetic, the capability
  table's lookup, rights and slot-closing code, the grace tracker and the
  page funnel for every input within stated bounds. Each seeded defect
  must make its harness fail.
* **Fuzzing** (`make check-fuzz`). The rule is that every parser of
  untrusted input gets a fuzz target when it lands; the known gaps are in
  `TODO.md`. The host fuzz targets include the boot image and its
  manifests, executable headers, the funnel's term decoder, the 9P codec
  and the shell's parser.
* **Sanitizers** (`make check-sanitizers`). Host tests of the C code run
  under AddressSanitizer and UndefinedBehaviorSanitizer, and the
  concurrency tests of the budget, capability, lane and log cores build
  under ThreadSanitizer.
* **Chokepoint build checks** (part of `make check`). Rules of the form
  "only X may do Y" fail `make check` on a new site, and the host test of
  each active rule seeds a violation to prove the check reports it. A rule
  whose sites are not written yet is marked pending and fails the moment a
  file it awaits appears.
* **Seeds** (`make check-native-seeds`, `make check-qemu-mutant`). Each
  seeded failure of the native threads, watchdog and interrupt suites must
  make its suite fail. A failure seeded into a copy of the Fiasco backend
  must make the QEMU gate fail, while an unmutated copy passes.
* **Stack proof** (`make check-stack-proof`, part of `make check`). The
  worst-case stack depth of the C17 cores is computed from their call
  graph. A frame over the cap, an unlisted indirect call or a cycle that
  is not a tail jump fails the build.
* **Reproducible images** (`make check-reproducible`). Two clean builds of
  the production boot image and its medium, both packing one build of the
  kernel, must be byte-identical, for QEMU's disk image and for the
  Raspberry Pi 4's SD card image, with BL31 built for each. In deterministic mode (`make check-qemu`, under TCG), two
  boots of the same image must write the same transcript.
* **Target suites** (`make check-qemu`). QEMU suites boot guests and check
  the running system: threads, memory, interrupts, crash records and the
  watchdog. `make check-conformance` is the harness for the kernel
  interface's conformance cases; each case lands with the call it tests,
  and the roster holds one pending case, so it boots no guest yet.
* **Review.** The project's rule is an internal review before every code
  commit, and an external review by a model from another vendor for
  designs and large changes.

These checks have limits. TLC checks a model, not the machine code. herd7
checks litmus tests, not the compiled lane. TSan finds data races but does
not show that an acquire and release protocol is right. The CBMC and TLC
reports state their bounds and assumptions.

## Host setup

Apple Silicon macOS is the primary host. You need:

* Ruby, any version, with minitest and REXML;
* GNU make, GNU sed, GNU timeout (`gtimeout`) and Perl;
* LLVM clang and lld, and the LLVM binary tools;
* AArch64 ELF GCC and binutils;
* Autoconf, Automake and Libtool, and a C and C++ compiler, which build
  fsimg, the tool that writes and verifies the EROFS images (`make setup`
  builds it);
* QEMU 11.1, with its `virt-11.1` machine;
* Node.js and pnpm, for `make web` (the browser client);
* xz (XZ Utils), which compresses the website's Raspberry Pi 4 download;
* a Homebrew JVM;
* Docker, a local engine or context, for the full stock OTP suites only.
  The [host oracle design](docs/design-host-oracle.md) describes its
  pinned Linux image and its isolation.

Install missing tools through Homebrew.

Point the build at your compiler. The tree is tested with LLVM 23.1;
the build does not check the version, so a compiler that is too old fails
with its own errors. Release images are built with exactly LLVM 23.1.3,
and their hashes are published so a rebuild can be compared.

Only LLVM will do, and not Apple's SDK clang or GCC: the build uses clang
as a cross compiler (`--target`) and its sanitizers with
`llvm-symbolizer`, links with lld and reads lld's link maps for the
image's source record, and admits into an image only the LLVM resource
headers that `config/provenance/llvm.json` lists, each by its own LLVM
license line. For Homebrew at
`/opt/homebrew` (Apple Silicon; Intel Macs use `/usr/local`, which
`brew --prefix` prints):

```sh
export ERX_CLANG=/opt/homebrew/opt/llvm/bin/clang
export ERX_LLD=/opt/homebrew/bin/ld.lld
export JAVA=/opt/homebrew/opt/openjdk/bin/java
export PATH=/opt/homebrew/bin:$PATH
```

For another installation, adjust the paths.

FreeBSD (x86-64, 16-CURRENT) is a host too. Install the same tools from
packages: `llvm23`, `gmake`, `coreutils` (for `gtimeout`), `gawk`,
`perl5`, `autoconf`, `automake`, `libtool`, `ruby` with
`rubygem-minitest` and `rubygem-rexml`, `b3sum`, `node`, and the
AArch64 ELF GCC and binutils (`aarch64-none-elf-gcc`), plus QEMU, a JVM
and Docker for what needs them as above. The Fiasco build takes the cross
tools under the port's `aarch64-none-elf-` prefix or Homebrew's
`aarch64-elf-`, preferring Homebrew's where both are on `PATH`. The base
system's `dtc` serves. Run the
top-level targets with GNU make (`gmake check`), and point the build at
the port's LLVM:

```sh
export ERX_CLANG=/usr/local/llvm23/bin/clang
export ERX_LLD=/usr/local/llvm23/bin/ld.lld
```

`make setup` finds the newest `/usr/local/llvmNN` by itself when these
are unset. The hosted runtime builds only on macOS, so on FreeBSD setup
leaves it out, `make check` names the test files that test only it
(`Runtime::HOSTED_ONLY_TESTS`) as not run on this host, and the other
tests that need it skip, saying so.

## Fresh worktree

A new checkout or git worktree needs its sources, the stock OTP oracle and
the native runtime built before `make check` can run. One command does it:

```sh
ERX_SOURCE_CACHE=/path/to/other/checkout/build/third_party make setup
```

`make setup` (`tools/erx setup --jobs N`) runs, in order: every source
`deps.lock` pins, in its order, except those named below, the
JIT oracle (`make oracle-bootstrap`), the `emu` oracle,
`tools/erx build runtime`, `tools/erx build rc-oracle` and
`tools/erx build fsimg`. A step whose output is already valid is
skipped, so a second run does nothing. Each build runs under a deadline
with its own log in `build/logs/`.

It never downloads. `ERX_SOURCE_CACHE` names another checkout's
`build/third_party`; the archives in the `downloads` directory beside it
are copied only after their SHA-256 matches `deps.lock`. Without it, the
sources must already be there from `make fetch`. It does not fetch
`arm-registers`, `tla-tools`, `herdtools7` or the oracle image
(`Erx::Setup::SKIPPED_SOURCES`): only `tools/erx sysreg refresh` reads
the first, only `make check-tla` uses the second, only
`make check-litmus` builds from the third, and the native oracle does
not use the fourth. If `ERX_CLANG` or `ERX_LLD`
is unset, the builds use Homebrew's `opt/llvm/bin/clang` and
`bin/ld.lld` under `HOMEBREW_PREFIX`, or under `brew --prefix` when that
is unset, and setup stops with a diagnostic when they are not there;
export them yourself for later commands.

## Fetch, bootstrap and check

Only `make fetch` downloads anything. Name your local Docker context, and
it fetches the oracle image too:

```sh
make fetch DOCKER_CONTEXT=NAME
make oracle-bootstrap
make check
```

The bootstrap builds stock native OTP 29.1.2 with the JIT, offline, from
the archive the fetch verified. To rebuild it, run
`tools/erx oracle build --backend native --flavour jit --clean`. The
modified dependencies live in `otp/`, `musl/` and `fiasco/`, each with
its recorded origin. LVGL is the git submodule `display/lvgl/lvgl`,
cloned from erXos's fork at the commit its gitlink records
(`display/lvgl/ORIGIN.md` says where it comes from): `make fetch` clones
it, without history, when it is not checked out, and `git submodule update --init display/lvgl/lvgl` does
the same by hand; `git clone --recurse-submodules` fetches it with the
tree.

`make check` is the everyday gate. It verifies the oracle runtime, the
source provenance and the ASCII rule. It generates every
artifact (ABI, hardware, system registers and terminal tables) into
`build/gen/`, none of which is checked in. It runs
the host tests, compares the generated text tables in Erlang with Ruby,
and runs the native ELF and archive integrations. It never runs the full
stock OTP suites and never downloads.

The slower gates run separately:

```sh
make check-reproducible
make check-sanitizers
make check-fuzz
make check-tla
make check-cbmc
make check-litmus
```

* **Reproducibility** keeps both full `ERXPACK` structural test fixtures
  and a report under `build/reproducible/`, and checks their structure,
  executable and provenance.
* **Sanitizers** run the host C readers, the `ERXPACK` validator and the
  ELF planner under ASan and UBSan, and the generated atomic accessor
  test and the concurrency tests of the budget, capability, lane and log
  cores under TSan. A sanitizer report ends its command. ASan checks stack
  use after return and lets allocations fail. Leak and
  initialization-order checks need Linux, so macOS reports them
  unsupported. `check-asan` and `check-tsan` both select this combined
  host gate. `check-ubsan` runs it too, then reports its kernel UBSan boot
  unsupported, as it cannot run until erXos's own kernel exists; the host
  run decides its status.
* **Fuzzing** runs the generated C ABI and manifest decoder and the
  `ERXPACK` and ELF C cores under libFuzzer with ASan and UBSan. It also
  runs the generated Erlang reader's hostile corpus and the Ruby parser
  targets. `tools/erx check-fuzz --seconds 5 --runs 100000 --seed 1`
  sets the budgets: seconds for the timed Ruby targets, runs for the C
  targets. The seed applies to the generated C ABI target and the timed
  Ruby targets. The other Ruby targets run 20,000 iterations with seed 1,
  and the logs record the pack and ELF libFuzzer seeds. Fuzzing the
  target's runtime and service parsers, and the production startup
  proof, remain unsupported.
* **TLA+** runs TLC offline and checks its jar against the pin.
  `TLA_TOOLS_JAR` points to another copy of the same bytes.
* **CBMC** runs the bounded model checker over the C cores' harnesses in
  `test/cbmc/` and checks that each seeded defect fails its harness. It
  needs the cbmc version `test/cbmc/roster.json` pins, from Homebrew
  (`CBMC` names another path), and writes its report to `build/cbmc/`.
* **Litmus** runs the weak-memory litmus tests of `test/litmus/` under
  herd7 and checks each protocol's answer and its broken twin's. herd7
  is built offline into `build/herdtools7/` from the herdtools7 release
  `make fetch` verified, the first time and whenever its pin or recipe
  changes (`tools/erx build herd7` builds it on its own). The build needs
  `brew install ocaml dune menhir ocaml-zarith`.

## Boot erXos

```sh
tools/erx boot
tools/erx boot --accel tcg --cpus 4
```

`tools/erx boot` builds the development boot image that the QEMU suites
boot, into `build/production-image/interactive/`. Then it runs the image
in QEMU with the guest's serial console on your terminal, and the Erlang
shell's `1>` prompt comes up. It needs the compiler variables from
[Host setup](#host-setup). It picks HVF when QEMU offers it, and TCG
otherwise. `--accel` chooses; `--cpus` sets the guest's CPUs, from 1 to
8, default 1. Quit with Ctrl-A then X. Ctrl-A then C switches to the
QEMU monitor and back. The first build of ERTS takes a while.
`--hostlink` also puts the guest's host link on a UNIX socket in
`build/production-image/hostlink/`, for `tools/erx load`, `files` and
`web`, and gives it a fresh data medium for `/data`; the boot prints the
`tools/erx web --socket PATH` line to run in another terminal.
`--without-web` builds the website's image instead, from its own manifest,
the development manifest without its web and display domains, into
`build/production-image/site/`, where `tools/build_site.rb` takes it; it
cannot be combined with `--hostlink`, which the web domain serves.

## Raspberry Pi 4 SD card

```sh
make pack PLATFORM=raspi4b
```

builds the Raspberry Pi 4's production image and its SD card, offline
from the pinned sources `make fetch` verified, into
`build/production-image/raspi4b/`: `sdcard.img`, a disk image to write
to a card; `boot/`, the same files as a directory, which also serves as
the firmware's network boot root; and `sdcard.img.receipt.json`, their
build record, beside the image's own. The same inputs give the same
bytes (`make check-reproducible`). The raspi4b QEMU suite packs the same
way and boots `boot/`'s files on QEMU's model, so it replaces what
`make pack` left there. Writing the card and what
to expect on a board is in
[design-platforms.md](docs/design-platforms.md#trying-a-card-on-a-board),
and the checklist for the SD card and Ethernet on a board
[after it](docs/design-platforms.md#the-sd-card-and-ethernet-on-a-board).

## Guest and stock oracle

```sh
make build
make run
make run ACCEL=tcg
make oracle-build DOCKER_CONTEXT=NAME FLAVOUR=emu
make check-oracle-host DOCKER_CONTEXT=NAME FLAVOUR=emu
make bench FLAVOUR=jit
tools/erx status
```

`make run` boots under HVF when QEMU offers it and TCG otherwise; `ACCEL=`
chooses. For BeamAsm, repeat the oracle commands with `FLAVOUR=jit`. The full
stock suites run inside an offline Linux container and keep their
failures, skips and incomplete results. `make check-oracle` runs
`tools/erx oracle qemu`: every `*_SUITE` of OTP's `emulator`, `kernel`, `stdlib` and `compiler` groups (not
the variants compiler's test Makefile generates from them) under Common
Test in the system domain under QEMU with HVF, on one CPU, compared case by case with stock OTP on the host,
run with as many schedulers, against the
tables of known differences in `test/oracle/hosted_known_differences/`, then musl's libc-test in test tasks
on four CPUs (`tools/erx check-libc-test hvf 4`). It takes six to seven hours: the emulator group about 100
minutes on stock and 60 on the guest, the kernel group about 110 and 30, the stdlib group about 40 and 30. Native benchmarks carry their own label, apart from Linux suite
results. Interpreter benchmarks need a separate native bootstrap, built
with `tools/erx oracle build --backend native --flavour emu`.

The aggregate host oracle target stops at its first failed suite. To
keep every outcome, run `tools/erx oracle run emulator`, `kernel` and
`stdlib` one by one, each with `--docker-context` and `--flavour`.

Every command keeps its
logs and deadline records under `build/logs/`, and a failed test keeps
its evidence. The [build design](docs/design-build.md) defines these
boundaries.
