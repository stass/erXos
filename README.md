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
* **Cross-platform.** AArch64 on QEMU `virt` comes first, then the
  Raspberry Pi 4 and 5. Other architectures are ports, not redesigns.

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
whether it is known. A shell pipe carries live records, not text. And a
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
  and pipes live Erlang records between commands. Toybox supplies the
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

erXos is in Phase 1 of the [roadmap](docs/plan.md), which brings the
system up on the stopgap Fiasco kernel. `tools/erx boot` builds a
development image and boots it in QEMU. Below, it boots under HVF on one
CPU. Then a few lines go to the shell. They list the running
applications, write a file to `/tmp`, catch a crash with a monitor, and
pass a token around a ring of 50,000 processes.

```
             __  __
   ___  _ __ \ \/ /  ___   ___
  / _ \| '__| \  /  / _ \ / __|
 |  __/| |    /  \ | (_) |\__ \
  \___||_|   /_/\_\ \___/ |___/

erXos
L4Re Microkernel on arm-64
Rev: Unknown version compiled with gcc 16.2.0 for Generic Platform
Build: #1 No date

development build: trusted code only
erx: boot image build 3a3f6f0136127701 index bd404218592d42c4da90518b49450cac83eab54a48424c046f56e79e52d42380 flags 0x1 archive 0x4022c000+0x20b0000 bootargs 0
[... Fiasco's own start-up lines ...]
erx: entropy: quality: low, from the counter alone
erx: root task: build 3a3f6f0136127701 index bd404218592d42c4da90518b49450cac83eab54a48424c046f56e79e52d42380 entries 231
erx: root task: manifest root_memory 402653184 baseline 134217728 units 3 pool pages 111153
erx: root task: watchdog 1,5,60
erx: erts: erl_start runs, 32 arguments
erx: erts: 1 schedulers and 1 dirty CPU schedulers hold executor slots
Erlang/OTP 29 [erts-17.1.1] [source] [64-bit] [smp:1:1] [ds:1:1:10] [async-threads:1]

Eshell V17.1.1 (press Ctrl+G to abort, type help(). for help)

% Which applications are running? Besides kernel and stdlib:
% the UART driver, the file servers and the runtime services.
1> [{A, element(2, application:get_key(A, description))} || {A, _, _} <- application:which_applications()].
[{erx_uart,"erXos UART drivers"},
 {erx_files,"erXos file servers"},
 {erx,"erXos runtime services"},
 {stdlib,"ERTS  CXC 138 10"},
 {kernel,"ERTS  CXC 138 10"}]

% Write a file to /tmp, served by a RAM file system written in
% Erlang, and read it back.
2> file:write_file("/tmp/hello.txt", <<"hello from erXos\n">>), file:read_file("/tmp/hello.txt").
{ok,<<"hello from erXos\n">>}

% Start a process that divides by zero, and catch its crash
% with a monitor. The shell carries on.
3> {_, Ref} = spawn_monitor(fun() -> 1 / erlang:list_to_integer("0") end), receive {'DOWN', Ref, process, _, {Reason, _}} -> {crashed, Reason} end.
=ERROR REPORT==== 1-Jan-1970::00:00:03.403519 ===
Error in process <0.103.0> with exit value:
{badarith,[{erlang,'/',[1,0],[{error_info,#{module => erl_erts_errors}}]}]}

{crashed,badarith}

% Define a ring: N processes, each passing a counted-down
% token to the next, until it reaches zero.
4> Ring = fun(N, Laps) -> Last = lists:foldl(fun(_, Next) -> spawn(fun Loop() -> receive 0 -> Next ! 0; T -> Next ! T - 1, Loop() end end) end, self(), lists:seq(1, N)), Alive = erlang:system_info(process_count), Last ! N * Laps, (fun Wait() -> receive 0 -> ok; T -> Last ! T - 1, Wait() end end)(), io:format("~b processes alive; one token went round a ring of ~b, ~b messages~n", [Alive, N, N * Laps]) end.
#Fun<erl_eval.41.130099583>

% Run it: 50,000 processes alive at once, one token,
% a million messages.
5> Ring(50000, 20).
50039 processes alive; one token went round a ring of 50000, 1000000 messages
ok
```

* **It boots to an Erlang shell** on QEMU `virt` (AArch64), under HVF and
  TCG, with 1 to 8 CPUs. The QEMU suites run under HVF; TCG runs only the
  deterministic-mode transcript and a boot smoke.
* **ERTS runs in user mode** as the system domain, on `liberx`'s Fiasco
  backend. OTP 29.1.2 and musl live in the tree, modified.
* **The serial console's driver** (PL011) is an Erlang process.
* **Files work.** The file protocol, per-domain namespaces and `/tmp` all
  run, `/tmp` on a RAM file system written in Erlang. `prim_file` reaches
  file servers through grants.
* **Storage works**: M6's demo of the [roadmap](docs/plan.md) runs. A
  virtio block driver in Erlang (`erx_blk`) serves the partitions of an
  MBR with extended boot records as windows. littlefs serves `/data`; a
  file synced there survives a power cut, checked under HVF. An EROFS
  reader in Erlang (`erx_erofs`), behind its funnel `erx_verity`, mounts
  images in the namespace. CRC-32C is the first per-byte primitive.
  `ruby tools/erx pack --medium` writes a QEMU disk image; the QEMU
  harness boots from it, playing the firmware, which reads the
  boot-selection record and boots the slot it names. The shell then reads
  the release's files from that slot's EROFS image at `/images/release`.
  The funnel does not check image hashes yet; that is M11.
* **The command shell has begun.** `erx_shell` holds rc's tokenizer and
  parser in Erlang, with a fuzz target and plan9port's rc built as the
  host oracle. The evaluator, commands and job control are not built.
* **Hosted mode** runs the runtime as a macOS process. There, OTP's
  compiler, stdlib, kernel and emulator suite groups are compared case by
  case with stock OTP, and each known difference is classified by cause
  (`test/oracle/hosted_known_differences/`). On QEMU the system domain
  runs kernel's `file_SUITE` and the whole compiler and stdlib groups
  against stock, with every difference classified.
* **The release** carries kernel, stdlib, compiler and runtime_tools (the
  last two loaded, not started), and the erXos applications `erx`,
  `erx_files`, `erx_uart`, `erx_blk` and `erx_shell`.
* **The build checks itself.** Generated ABI and hardware layers,
  reproducible boot images, fuzzing, ASan, UBSan, TSan and TLA+ models
  all run as build gates.
* **Designed but not built yet:** erXos's own kernel, domains beyond the
  system domain, the rest of the command shell, networking, the display
  and web UI, and the POSIX-lite layer. Each has a design document in
  [docs/](docs/).

## Host setup

Apple Silicon macOS is the primary host. You need:

* Ruby, any version, with minitest and REXML;
* GNU make, GNU timeout (`gtimeout`) and Perl;
* LLVM clang 23.1.3, lld and the LLVM binary tools;
* AArch64 ELF GCC and binutils;
* QEMU 11.1, with its `virt-11.1` machine;
* a Homebrew JVM;
* Docker, a local engine or context, for the full stock OTP suites only.
  The [host oracle design](docs/design-host-oracle.md) describes its
  pinned Linux image and its isolation.

Install missing tools through Homebrew.

Point the build at your compiler. Apple's SDK clang will not do: the
checks compare clang's and lld's versions, and the compiler's resource
headers, with `config/provenance/llvm-23.1.3.json`. For Homebrew at
`/opt/homebrew`:

```sh
export ERX_CLANG=/opt/homebrew/opt/llvm/bin/clang
export ERX_LLD=/opt/homebrew/bin/ld.lld
export JAVA=/opt/homebrew/opt/openjdk/bin/java
export PATH=/opt/homebrew/bin:$PATH
```

For another installation, adjust the paths.

## Fresh worktree

A new checkout or git worktree needs its sources, the stock OTP oracle and
the native runtime built before `make check` can run. One command does it:

```sh
ERX_SOURCE_CACHE=/path/to/other/checkout/build/third_party make setup
```

`make setup` (`tools/erx setup --jobs N`) runs, in order: every source
`deps.lock` pins, in its order, except those named below, the
JIT oracle (`make oracle-bootstrap`), the `emu` oracle,
`tools/erx build runtime` and `tools/erx build rc-oracle`. A step whose output is already valid is
skipped, so a second run does nothing. Each build runs under a deadline
with its own log in `build/logs/`.

It never downloads. `ERX_SOURCE_CACHE` names another checkout's
`build/third_party`; the archives in the `downloads` directory beside it
are copied only after their SHA-256 matches `deps.lock`. Without it, the
sources must already be there from `make fetch`. It does not fetch
`arm-registers`, `tla-tools`, the oracle image or the Linux guest's
kernel and busybox (`Erx::Setup::SKIPPED_SOURCES`): only
`tools/erx sysreg refresh` reads the first, only `make check-tla` uses
the second, the native oracle does not use the third, and only
`make check-erofs-oracle` boots the Linux guest. If `ERX_CLANG` or `ERX_LLD`
is unset, the builds use `/opt/homebrew/opt/llvm/bin/clang` and
`/opt/homebrew/bin/ld.lld`; export them yourself for later commands.

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
its recorded origin.

`make check` is the everyday gate. It verifies the oracle runtime, the
source provenance and the ASCII rule. It checks every generated
artifact: ABI, hardware, system registers and terminal tables. It runs
the host tests, compares the generated text tables in Erlang with Ruby,
and runs the native ELF and archive integrations. It never runs the full
stock OTP suites and never downloads.

The slower gates run separately:

```sh
make check-reproducible
make check-sanitizers
make check-fuzz
make check-tla
```

* **Reproducibility** keeps both full `ERXPACK` structural test fixtures
  and a report under `build/reproducible/`, and checks their structure,
  executable and provenance.
* **Sanitizers** run the host C readers, the `ERXPACK` validator and the
  ELF planner under ASan and UBSan, and the generated atomic accessor
  test under TSan. A sanitizer report ends its command. ASan checks stack
  use after return and lets allocations fail. Leak and
  initialization-order checks need Linux, so macOS reports them
  unsupported. `check-asan` and `check-tsan` both select this combined
  host gate. `check-ubsan` runs it too, then fails on purpose: its kernel
  UBSan boot cannot run until erXos's own kernel exists.
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
`tools/erx oracle qemu`: `file_SUITE` and every `*_SUITE` of OTP's `stdlib` and `compiler` groups (not
the variants compiler's test Makefile generates from them) under Common
Test in the system domain under QEMU with HVF, on one CPU, compared case by case with stock OTP on the host,
run with as many schedulers, against the
tables of known differences in `test/oracle/hosted_known_differences/`, then musl's libc-test in test tasks
on four CPUs (`tools/erx check-libc-test hvf 4`). The stdlib group takes about 40 minutes on stock and 30 on
the guest. It says it is partial: OTP's
`emulator` and `kernel` groups do not
run there whole yet. Native benchmarks carry their own label, apart from Linux suite
results. Interpreter benchmarks need a separate native bootstrap, built
with `tools/erx oracle build --backend native --flavour emu`.

The aggregate host oracle target stops at its first failed suite. To
keep every outcome, run `tools/erx oracle run emulator`, `kernel` and
`stdlib` one by one, each with `--docker-context` and `--flavour`.

Every command keeps its
logs and deadline records under `build/logs/`, and a failed test keeps
its evidence. The [build design](docs/design-build.md) defines these
boundaries.
