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

erXos is in Phase 1 of the [roadmap](docs/plan.md), which brings the
system up on the stopgap Fiasco kernel. Its Phase 1b, which moves the
user-facing parts into domains of their own, is under way. `tools/erx
boot` builds a development image and boots it in QEMU. Below, it boots
under HVF on one CPU of a 256 MiB machine, into the command shell. There a
few commands list the root, write a file to `/tmp`, read it back and
count the processes; then `erl` starts the Erlang shell, which catches a
crash with a monitor and passes a token around a ring of 5,000
processes. Lines starting `% ` in the Erlang shell are notes added here.

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
erx: boot image build df85638cc0daa5ea index 97622c2ebb3940e67f01874bc45165c42c9d636437029447b0e279a1e1dbccc0 flags 0x1 archive 0x4022c000+0x17b4000 bootargs 0
[... Fiasco's own start-up lines ...]
erx: entropy: quality: low, from the counter alone
erx: root task: build df85638cc0daa5ea index 97622c2ebb3940e67f01874bc45165c42c9d636437029447b0e279a1e1dbccc0 entries 377
erx: root task: manifest root_memory 100663296 baseline 81788928 units 3 pool pages 29575
erx: root task: watchdog 1,5,60
erx: erts: erl_start runs, 40 arguments
erx: erts: 1 schedulers and 1 dirty CPU schedulers hold executor slots
Erlang/OTP 29 [erts-17.1.1] [source] [64-bit] [smp:1:1] [ds:1:1:10] [async-threads:1]

rc: the command shell; erl starts the Erlang shell
% # The command shell runs rc's language, written in Erlang.
% ls -1 /
NOTICES
bin
data
lib
manifest
proc
releases
root
tmp
% echo hello from erXos > /tmp/hi
% cat /tmp/hi
hello from erXos
% # How many processes run? Each is an Erlang process.
% ps | wc -l
      62
% erl
Eshell V17.1.1 (type help(). for help)

% Crash a process that divides by zero, and catch it
% with a monitor. The shell carries on.
1> {_, R} = spawn_monitor(fun() -> 1 / list_to_integer("0") end).
=ERROR REPORT==== 1-Jan-1970::00:00:02.651025 ===
Error in process <0.150.0> with exit value:
{badarith,[{erlang,'/',[1,0],[{error_info,#{module => erl_erts_errors}}]}]}

{<0.150.0>,#Ref<0.3910384898.1.60465>}
2> receive {'DOWN', R, _, _, {E, _}} -> {crashed, E} end.
{crashed,badarith}

% A ring of N processes passes a token round it Laps times.
3> Ring = fun(N, Laps) ->
..     Last = lists:foldl(fun(_, Next) ->
..         spawn(fun Loop() -> receive 0 -> Next ! 0;
..                   T -> Next ! T - 1, Loop() end end)
..       end, self(), lists:seq(1, N)),
..     Alive = erlang:system_info(process_count),
..     Last ! N * Laps,
..     (fun Wait() -> receive 0 -> ok;
..                    T -> Last ! T - 1, Wait() end end)(),
..     {Alive, N * Laps}
..   end.
#Fun<erl_eval.41.130099583>

% 5,000 processes alive at once, 100,000 messages.
4> Ring(5000, 20).
{5061,100000}
```

* **It boots to the command shell** on QEMU `virt` (AArch64), under HVF and
  TCG, with 1 to 8 CPUs. The QEMU suites run under HVF; TCG runs the
  deterministic-mode transcript and a boot smoke, and at the landing gate
  `tools/erx check-qemu --remote DEST` may move the multi-CPU cells of
  long suites to a second host under TCG while this one is busy.
* **ERTS runs in user mode** as the system domain, on `liberx`'s Fiasco
  backend. OTP 29.1.2 and musl live in the tree, modified.
* **The serial console's driver** (PL011) is an Erlang process.
* **Files work.** The file protocol, per-domain namespaces and `/tmp` all
  run, `/tmp` on a RAM file system written in Erlang. `prim_file` reaches
  file servers through grants, and that works across domains: a file
  server in one domain serves a client in another over their connection.
* **Storage works**: M6's demo of the [roadmap](docs/plan.md) runs. A
  virtio block driver in Erlang (`erx_blk`) serves the partitions of an
  MBR with extended boot records as windows. It runs in the storage
  domain, an interpreter service domain that holds the block device, which the
  development manifest configures and the domain service starts at boot.
  littlefs serves `/data` there; a file synced there survives a kill of the
  machine, and a littlefs failure ends the domain, whose restart mounts
  `/data` afresh, both checked under HVF. A power cut on a real disk also
  needs the device to flush its write cache, which is not built yet
  ([TODO.md](TODO.md)). The system shell and root's session
  both read and write `/data` through the storage domain's `data` facet,
  and both reach it again once the storage domain has restarted. Under HVF,
  root's session writes a file, the system shell reads it, and the file is
  read again after the storage domain restarts. The system shell restarts the
  block driver through the storage domain's driver-control facet, at
  `erl`: `erx_driver_ctl:restart(erx:cap(storage_ctl), block)`, or by
  writing `reset` to the block device's `/dev/N-virtio,mmio/ctl`, beside
  its `status`: in the system shell, `/dev` lists the block device, shows
  its status and takes the control words `stop`, `start` and `reset`. An EROFS
  reader in Erlang (`erx_erofs`), behind its funnel `erx_verity`, mounts
  images in the namespace. CRC-32C is the first per-byte primitive.
  `make pack` (`tools/erx pack --medium`) writes a QEMU disk image into
  `build/production-image/qemu-virt/`; the QEMU
  harness boots one built the same way, playing the firmware, which reads the
  boot-selection record and boots the slot it names. The harness then
  reads the release's files from that slot's EROFS image at the storage
  domain; the image is not yet served to the system domain.
  The funnel does not check image hashes yet; that is M11.
* **The command shell works at the console.** The console's first shell
  is an rc-language command shell, written in Erlang, and `erl` in it
  starts the Erlang shell; `q()` there returns to the command shell.
  The language has variables, lists, `for`, `if`, functions, pipelines,
  redirections, `cd` and `pwd`, with `Ctrl-C` ending the running line.
  Its commands are Erlang commands (`echo`, `cat`, `ls`, `wc`, `grep`,
  `sort`, `mkdir`, `rm`, `mv`, `cp`, `ps`, `top`, `mount`, `uname`, `dmesg`, `ifconfig`,
  `ping`, `host`, `erl`, `true` and `false`); every pipe carries text, and `ls`, `ps`, `grep`, `sort` and
  `wc` print what FreeBSD's do for the options they offer; `uname` takes
  FreeBSD's flags and layout, and `uname -v` names the build. `dmesg` prints
  the kernel log from `/proc/kernel/log`, which reads the log without taking
  it from the console and marks the records it cannot show, overwritten or
  unreadable, as `[missing N]`. `top` shows
  the process table under a header of uptime, memory and run queue, read
  from the one tree of system values that `/proc` also serves. Every
  runtime's `/proc`, `top` and `dmesg` read through the inspect facet, and
  the kernel log's old `log` facet is gone. A figure
  the stopgap kernel measures only in part says so and names its source.
  Its language is checked against
  plan9port's rc, built on the host as the oracle. Job control works for
  Erlang commands: `&`, `Ctrl-Z`, `jobs`, `fg`, `bg` and `kill`. Running
  programs is not on master yet.
* **Programs have pipes, but nothing runs them yet.** A program has a
  descriptor table and pipe ends set up from its startup message, and a
  read or write on a pipe end waits until the other side is ready. The
  musl seam that lets a C program use them is not built, so no C program
  uses pipes yet.
* **The start table runs.** The start service merges the manifest's
  `start` rows with `/apps/rc.conf` and keeps each enabled row's session
  under a supervisor of its own. `service` enables, disables, starts and
  stops rows as FreeBSD's does, `service -e` lists what starts, and
  `/proc/apps` shows each row's state.
* **The Raspberry Pi 4 boots on QEMU's `raspi4b` model.** TF-A BL31 hands
  off to Fiasco, and the system boots to the serial shell on the mini
  UART. It runs under TCG only, because QEMU cannot run this model under
  HVF. The packed card's device tree, whose `serial0` is the mini UART,
  boots on a 4 GB board.
* **The machine is an object** (M4). A host link over the second serial
  line lets `tools/erx load` and `watch` replace modules in the running
  system, and `tools/erx files` read the guest's files over 9P2000.L; `tools/erx boot
  --hostlink` boots the guest with that link on a UNIX socket and a fresh
  copy of the release disk, so `/data` starts empty. At
  the Erlang shell, `erx:i()` shows processes and kernel objects, `source(Pid)` shows the source line a process is at, and
  `erx:trace/1` streams trace events; `/proc` serves the same records as
  read-only files. Values the stopgap kernel cannot measure show as
  unsupported or partial, never invented.
* **Domains work on the stopgap** (1b-A). Each runs its own ERTS, as the
  interpreter or as BeamAsm, in an address space of its own, on
  `liberx`'s Fiasco backend and its domain library. In the booted system
  the domain service, `erx_domain`, starts the manifest's configured
  domains and creates others on request; only the BeamAsm image, whose
  manifest marks it, gets a space that can hold generated code.
  `erx_domain:introduce/2` connects two domains, whose processes then
  message and call each other as Erlang nodes do; when either end goes,
  both are told `noconnection`, and a crashed domain leaves a crash
  record. A message from another domain is acted on only by its protocol's
  owner. Root's session domain runs at boot and takes the UART. The
  configured domains serve facets that the domain service mints from the
  manifest and makes anew when a domain restarts. A device's holder
  domain binds its interrupt line and opens the device in the form it was
  given. A connection between domains costs about 132 KiB.
* **Hosted mode** runs the runtime as a macOS process, on Apple Silicon
  and on x86_64 Macs. There, OTP's
  compiler, stdlib, kernel and emulator suite groups are compared case by
  case with stock OTP against tables of known differences, each with its
  cause (`test/oracle/hosted_known_differences/`). On QEMU the system domain
  runs all four groups whole against stock (`make check-oracle`), with
  every difference classified or tracked in TODO.md.
* **The system release** carries kernel, stdlib, compiler and
  runtime_tools (the last two loaded, not started) and the erXos
  applications the system domain runs. The storage applications
  (`erx_blk`, `erx_storage`) and the network ones (`erx_net`,
  `erx_net_client`) ship only in the domain release, so the system
  domain holds no driver or network code.
* **A demo runs in the browser**, on an AArch64 emulator built from v86,
  with a disk that keeps its files across a power cut and a menu of
  hardware faults (dead, corrupt or hung disk, corrupt RAM, an interrupt
  storm, a frozen CPU, a power cut) that shows how the system meets each.
  When the machine goes down it prints a picture and its crash record.
* **The build checks itself.** Generated ABI and hardware layers,
  reproducible boot images, fuzzing, ASan, UBSan, TSan, TLA+ models (of
  the lane, the connection and links among others) and herd7 litmus tests
  of memory ordering all run as build gates.
* **erXos's own kernel has begun** as host-built C17 cores: the object
  store, the capability table, budgets, the grace tracker and the page
  funnel, with host tests, fuzzing and a CBMC model-checking gate. None
  of it boots yet; the modified Fiasco is still the running kernel.
* **The network stack is growing on the host** as an Erlang translation
  of FreeBSD's logic (`erx_net`), tested there: Ethernet, ARP and one
  neighbour table shared with IPv6 neighbour discovery and its duplicate
  address detection, IPv4 and IPv6 with fragment reassembly, ICMP and
  ICMPv6 with their rate limits, UDP, and for TCP its wire format, RTT,
  MSS, initial sequence numbers, ECN, SACK blocks and the RFC 6675
  scoreboard with duplicate-ACK loss detection. TCP's connection now runs
  as a pure step from SYN to TIME-WAIT, with its timers, the syncache,
  ICMP errors and path MTU, and an explorer that walks its states,
  across sequence-number wrap too, checking RFC 9293's rules. Frames are
  classified on input and framed on output, and DHCP for IPv4 is decided.
  The Internet checksum and SipHash-2-4 are its per-byte primitives. On
  stock OTP it runs as processes against QEMU's user networking: it takes
  a DHCP lease, answers ARP and ping, echoes UDP, and opens TCP
  connections through `gen_tcp`'s calls, echoing 1 MiB each way off a
  host server. On FreeBSD it also runs over a tap device through its tap
  transport, where a vnet jail resolves and pings it. On erXos under QEMU it
  runs in a network domain of its own over its virtio-net driver, takes a
  DHCP lease and answers ARP and ping; root's session reaches it through
  its `net` grant, and the system domain holds neither the network device
  nor the stack, so the system shell refuses `ifconfig`, `ping` and `host`
  and they work in root's session. There `ifconfig` and
  `ping` show its interface and ping slirp's gateway in FreeBSD's layout,
  and names resolve: the lease's name servers and domain reach `inet_db`
  through the grant, `gen_udp` and `gen_tcp` go through the grant by
  default, and the `host` command looks names and addresses up in
  FreeBSD's lines. TCP, UDP and ICMP sockets work over a per-client
  grant that admits every message. Its fast path (checksums folded into the copy, whole runs of
  segments sent and merged on receive) was measured on the FreeBSD
  x86-64 test host, over a native FreeBSD tap, with erXos running in
  hosted mode (the medians of 5 runs). Bulk send reaches about 2,470
  Mbit/s and bulk receive about 3,600 Mbit/s. A request and reply of 64
  bytes does about 15,000 transactions a second, and about 87,000 with 16
  in flight. For scale, lwIP, a small stack that stands as the baseline,
  on the same tap (its 64 KiB window variant) reaches 6,537 Mbit/s
  sending and 6,809 Mbit/s receiving, so bulk transfer is still well
  behind it. The raw data lives outside this repository.
* **The display has host-built parts:** the screen's composition
  (`erx_screen_core`), the single-window policy with its reserved chord
  and `wctl`, the widget model's deltas, `ui.txt` with its generated
  schema and binary form in Erlang, C and TypeScript, presentation types
  generated from the inspection schema, LVGL built on the host, and the
  web client's protocol and connection core. No screen shows it yet.
* **A browser shows the machine's records:** run `make web` first,
  which builds the client offline from pinned packages; boot with
  `tools/erx boot --hostlink`, run the `tools/erx web --socket PATH`
  line it prints once root's session has started, and open the URL
  that prints. The page
  shows the machine's record, attribute by attribute with each value's
  reporter, and its children as links; on the stopgap kernel every
  value reads `[unsupported]`. A `/proc/...` address shows the record
  of that path as root's session sees it, such as `/proc/processes`,
  the session's own processes, each a link to its record; a path the
  session cannot see ends with `scope`. Records are the only view so far.
* **Designed but not built yet:** the rest of erXos's own kernel, the
  rest of the command shell, the display on a
  screen, the rest of the browser client, and the POSIX-lite layer. Each has a design document in
  [docs/](docs/).

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
  processor may reorder memory accesses. The ten litmus tests (small
  programs with a stated bad outcome) in `test/litmus/` cover the lane's
  wake handshake and ring positions, under Arm's AArch64 memory model and,
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
  or the deadlock check they name. The roster has 34 configurations,
  four of them fixtures that test the runner itself. The models for the
  host link's sessions, the update protocol and the scheduler's
  cross-CPU protocol are planned and not written.
* **CBMC, a bounded model checker for C** (`make check-cbmc`). Six
  harnesses check the budget arithmetic and the capability table's lookup,
  rights and slot-closing code for every input within stated bounds. Nine
  seeded defects must each make a harness fail.
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
`config/manifest/qemu-virt-site.txt`, which has no web domain, into
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
[design-platforms.md](docs/design-platforms.md#trying-a-card-on-a-board).

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
